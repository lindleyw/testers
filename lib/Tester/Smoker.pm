use strict;
use warnings;

package Tester::Smoker {

    use Mojo::Base -base;
    use Mojo::File;

    use Mojo::SQLite;

    use SQL::Abstract::More;

    has 'database';
    has 'rebuild';     # Flag to rebuild database.  Useful for debugging or reprovisioning
    has 'log';
    has 'verbose';
    has 'sql' => sub { # Set during instantiation; or, create object
        my ($self) = @_;
        if (defined $self->database) {
            Mojo::SQLite->new('sqlite:' . $self->database);
        }
    };
    has 'config';
    has 'build_dir';

    use Minion;
    has 'minion' => sub {
      my ($self) = @_;
      Minion->new( SQLite => 'sqlite:'. $self->database );
    };

    use App::cpanminus::reporter;

    sub new {
        my $class = shift;
        my $self = $class->SUPER::new(@_);

        $self->build_dir(App::cpanminus::reporter->new->build_dir);
        $self->sql->abstract(SQL::Abstract::More->new());

        $self->sql->migrations->name('smoker_migrations')->
          from_file('sqlite_migrations');
          # from_data('main', 'sqlite_migrations');

        $self->sql->migrations->tap(sub { $self->rebuild and $_->migrate(0) })->migrate;
        my $jmode = $self->sql->db->query('PRAGMA journal_mode=WAL;');
        if ($jmode->arrays->[0]->[0] ne 'wal') {
            warn 'Note: Write-ahead mode not enabled';
        }
        
        return $self;
    }

    use Sys::Hostname;        # hostname() returns our fqdn, if available
    use Config;

    sub my_environment {
        # Returns the id of our native (non-Perlbrew) environment, adding it if required
        my $self = shift;

        my $env = $self->sql->db->query('SELECT id FROM environments WHERE host=? AND perl=? AND perlbrew IS NULL',
                                        hostname(),$Config{version})->hashes;
        if ($env->size) {
            return $env->first->{id};
        } else {
            my @args = (hostname(), @Config{qw(osname osvers version)});
            return $self->sql->db->query('INSERT INTO environments (host, osname, osvers, perl) VALUES (?,?,?,?)',
                                         hostname(), @Config{qw(osname osvers version)})->last_insert_id;
        }
    }

    sub update_perl_versions {
        my $self = shift;

        # Do we have multiple Perl versions via Perlbrew?
        my @perl_versions = grep {length} split(/\s*\*?\s+/, `perlbrew list`);
        if (! scalar @perl_versions) {
            # No Perlbrew; use only native ('this') Perl build. Leave old version records.
            $self->my_environment();
        } else {
            foreach my $v (@perl_versions) {
                my $id = eval {
                    $self->sql->db->query('INSERT INTO environments(host, perlbrew) VALUES (?,?)',
                                          hostname(), $v)->last_insert_id;
                };
                if (defined $id) {
                    # Newly-added version
                    my $version_specific = `perlbrew exec --with $v perl -MConfig -MSys::Hostname -e 'print join("\n", %Config{qw(osname osvers version)})'`;
                    # returns, e.g.:  (perl-5.24.1)\n===...===\n and results
                    if ($version_specific =~ /===\s+(.*?)\s*\z/s) {
                        my $version_info = {split /\n/, $1};
                        eval {
                            $self->sql->db->query('UPDATE environments '.
                                                  'SET osname=?, osvers=?, perl=? WHERE id=?',
                                                  $version_info->@{qw(osname osvers version)}, # hash slice
                                                  $id
                                                 );
                        };
                    }
                }
            }
        }
    }

    sub save_module_info {
        my ($self, $fields) = @_;
        my $id = eval {
                $self->sql->db->query('INSERT INTO modules(name, version, released, author, relative_url) '.
                                      'VALUES (?,?,?,?,?)',
                                      $fields->{main_module},
                                      @{$fields}{qw(version date author download_url)})
                ->last_insert_id;
            };
        return $id;
    }

    sub update_module {
        my ($self, $module_name) = @_;

        my $ua = Mojo::UserAgent->new();
        my $source_url = Mojo::URL->new($self->config->{metacpan}->{release}); # API endpoint
        push @{$source_url->path->parts}, 'CPAN';
        my $result = $ua->get($source_url);
        if ($result->res->{code} == 200) {
            my $module_fields = $result->res->json;
            $module_fields->{_db_id} = $self->save_module_info($module_fields);  # keep new id value
            return $module_fields;
        }
        return undef;
    }

    ################################################################


    # use Date::Parse;
    my %months = (jan=>1,feb=>2,mar=>3,apr=>4,may=>5,jun=>6,jul=>7,aug=>8,sep=>9,oct=>10,nov=>11,dec=>12);

    sub _dom_extract {
        my $module_tgzs = shift;

        my @modules;
        $module_tgzs->each( sub {
                                my $module_node = shift;
                                my $module_info = {};
                                @{$module_info}{qw(author name version)} = ( $module_node->attr('href') =~ # from the URL,
                                                                             m{(\w+)/([^/]+?)-?v?([0-9a-z.]+)?\.tar\.gz}
                                                                           ); # Extract into hash slice
                                $module_info->{name} =~ s/-/::/g;

                                # Extract content and remove any leading whitespace
                                my $module_info_text = $module_node->next_node->content =~ s/\A\s+//r =~ s/\s+\z//r;
                                ($module_info->{size}, my $m_day, my $m_mon, my $m_year) = split(/\s+/, $module_info_text, 4);
                                # Convert human units to octets:
                                $module_info->{size} =~ s/^([0-9.])+([kM])/$1*({k=>1024,M=>1024*1024}->{$2})/e;
                                # use Date::Parse and do str2time() of
                                # date for epoch timestamp, or simply
                                # put into format SQLite understands:
                                $module_info->{released} = sprintf('%4d-%02d-%02d', $m_year, $months{lc($m_mon)}, $m_day);
                                push @modules, $module_info;
                            } );
        return Mojo::Collection->new(@modules);
    }

    sub enable_recent {
      # Get the list of most recently updated modules from source; default to
      # http://cpan.cpantesters.org/modules/01modules.mtime.html
      my ($self, $info, $source) = @_;

      my $source_url = Mojo::URL->new($source // $self->app->config->{cpan_testers} );
      push @{$source_url->path->parts},
        'modules',
        $self->app->config->{cpan_recent} // '01modules.mtime.html';

      my $ua = Mojo::UserAgent->new();
      my $module_dom = $ua->get($source_url)->result->dom;

      # Create a list of modules
      my $modules = _dom_extract($module_dom->find('a[href$=".tar.gz"]'));

      $modules->each(sub { $self->app->db
                             ->query('INSERT OR REPLACE INTO modules(name, version, released, author, relative_url) '.
                                     'VALUES (?,?,?,?,?)',
                                     $_->{name}, $_->{version}, $_->{released}, $_->{author}, $_->{relative_url});
                         });

      # Convert list to a regex which selects exactly those modules
      my $regex = "^(?x:\n.^  # never matches, only purpose is to let things align nicely\n" .
        '    # Recent modules list from ' . $source_url . "\n    |".
        $modules->map( sub { $_->{name} . '  # Version ' . $_->{version} . '  ' . $_->{released} })->join("\n   |")     
        . "\n)";
      # Save regex in module_flags table
      my $saved = $self->app->db->query('INSERT OR REPLACE INTO module_flags (priority, origin, author, disable, regex) '.
                                        'VALUES (?,?,?,?,?)',
                                        $info->{priority}, $info->{reason}, $info->{author}, $info->{disabled} // 0, $regex
                                       );
      return 1;
    }

    ################################################################

    sub _text_line_extract {
        my ($module_text) = @_;
        
        my $vals = {};          # populate with a hash slice:
        @{$vals}{qw(name version relative_url)} = split /\s+/, $module_text;
        $vals->{author} = ($vals->{relative_url} =~ m{^./../(\w+)/})[0];
        $vals->{version} = undef if ($vals->{version} eq 'undef'); # Replace text 'undef'
        return $vals;
    }

    sub _text_extract {
        my ($module_text_list) = @_;
      
        # Extract from text file, skipping header, with header/body as SMTP message
        my $header = 1;
        my $module_tgzs = Mojo::Collection->new (
                                              map {
                                                  if ($header) {
                                                      $header = $_ !~ /^$/; # false once we reach blank line
                                                      (); # and skip this
                                                  } else {
                                                      _text_line_extract($_);
                                                  }
                                              } ( split (/\n/, $module_text_list ) )
                                             );
        return $module_tgzs;
    }

    sub update {
        my ($self, $source) = @_;

        my $module_list;
        my $module_dom;

        # If no source specified, load default remote module list
        my $source_url = Mojo::URL->new($source // $self->config->{cpan_testers});

        if ($source_url->protocol || $source_url->host) { # Remote file
            unless (length($source_url->path) > 1) { # no path, or '/'
                push @{$source_url->path->parts}, ( 'modules',
                                                    $self->config->{cpan_modules} //
                                                    '02packages.details.txt'
                                                  );
            }
            my $ua = Mojo::UserAgent->new();
            $module_list = $ua->get($source_url)->result;
            die "Can't download modules list: ".$module_list->message
                unless $module_list->is_success;
            if ($source_url->path =~ /\.htm/) {
                $module_dom = $module_list->dom;
            } else {
                $module_list = $module_list->body; # plaintext contents
            }
        } else {                # Local file
            $module_list = Mojo::File->new( $source)->slurp;
            die "No module list file" unless length($module_list);
            $module_dom = Mojo::DOM->new($module_list) if ($module_list =~ /<html/i);
        }

        my $module_tgzs;
        if (defined $module_dom) {
          $module_tgzs = _dom_extract($module_dom->find('a[href$=".tar.gz"]'));
        } else {
          $module_tgzs = _text_extract($module_list);
        }
        ; $DB::single = 1;
        $module_tgzs->each(sub { $self->sql->db
                                   ->query('INSERT OR REPLACE INTO modules(name, version, released, author, relative_url) '.
                                           'VALUES (?,?,?,?,?)',
                                           $_->{name}, $_->{version}, $_->{released}, $_->{author}, $_->{relative_url});
                               });
        return $module_tgzs->size;
    }

    ################################################################

    use YAML;

    sub save_regex {
        my ($self, $source) = @_;

        # Save to the database, a local or remote copy of a regex
        # which will be applied against the list of modules, and which
        # will disable (or enable) them.

        # If no source specified, load default remote file
        my $source_url = Mojo::URL->new($source // $self->config->{cpan_source});
        my $disabled_list;
        my ($priority, $author, $version, $reason);

        if ($source_url->protocol || $source_url->host) {
            # Remote file.  Retrieve
            # https://fastapi.metacpan.org/v1/release/CPAN and look at
            # {version}
            my $module = $self->update_module('CPAN');
            ($author, $version) = @{$module}{qw(author version)};
            if ($version ne CPAN::Wrapper::version()) {
                $self->log->warn ("Our cpan=$CPAN::VERSION but remote is $version");
            }

            return 1 unless $module->{_db_id};  # Already in database; use cached instead of storing anew

            $reason = "${author}/CPAN-${version}";
            $priority = 100;    # Default for remote file
            unless ($source_url->path  =~ /\.\w+/) { # If just a path, without a filename+extension: use default
                push @{$source_url->path->parts}, ( $author,
                                                    'CPAN-' . $version,
                                                    'distroprefs',
                                                    $self->config->{cpan_disable} //
                                                    '01.DISABLED.yml'
                                                  );
                $source_url->path->trailing_slash(0);
                my $ua = Mojo::UserAgent->new();
                $disabled_list = $ua->get($source_url)->result;
                unless ($disabled_list->is_success) {
                    $self->log->warn("Can't download disabled list: ".$disabled_list->message);
                    return 0;
                }
                $disabled_list = $disabled_list->body;
            }
        } else {
            # Local file
            $reason = $source;
            $priority = 50;     # Default for local
            $disabled_list = Mojo::File->new( $source)->slurp;
            unless (length($disabled_list)) {
                $self->log->error("No module list file");
                return 0;
            }
        }

        # Decode and save as meta-information in the Modules list
        my $matchfile = eval{YAML::Load($disabled_list)};
        my $saved = $self->sql->db->query('INSERT OR REPLACE INTO module_flags (priority, origin, author, disable, regex) '.
                                          'VALUES (?,?,?,?,?)',
                                          $priority, $reason, $author, $matchfile->{disabled}, $matchfile->{match}{distribution}
                                         );
        
        1;
    }

    ################################################################

    sub _apply_regexes {
        my ($self, $module_id) = @_; 

        # For each available enable/disable list, prepare to apply in priority order
        my $regex_list = eval{$self->sql->db->query('SELECT * FROM module_flags ORDER BY priority DESC, added DESC');};
        return undef unless defined $regex_list;
        $regex_list = $regex_list->hashes;

        my $module_info = $self->sql->db->query('SELECT * FROM modules WHERE id=?', $module_id)->hashes;
        return 1 unless $module_info;
        $module_info = $module_info->first;
        my $disabled = 0;
        my $disabled_by;

        $regex_list->each( sub {
                               if ( join('/', $module_info->{author}, $module_info->{name}) =~ $_->{regex} ) {
                                   $disabled = $_->{disable};
                                   $disabled_by = $disabled ? $_->{id} : undef;
                               }
                           } );
        # Save final enabled/disabled status
        eval { $self->sql->db->query('UPDATE modules SET disabled_by = ? WHERE id = ?',
                             $disabled_by, $module_info->{id}); };
        return $disabled;
    }

    ################################################################

    use TestModule;

    sub test {
        my $self = shift;
        my $minion_job = shift;
        my $args = {@_};

        my $module_id = $args->{module_id};
        my $env_id = $args->{environment_id};
        my ($perlbuild, $perlbuild_id);
        my $grade;

        if (! $module_id) {
            $self->log->error("No module_id");
            return 0;
        }

        my $module_info = $self->sql->db->query('SELECT name, version, author, relative_url FROM modules WHERE modules.id=?',
                                            $module_id)->hashes;
        return 0 unless defined $module_info;
        $module_info = $module_info->first;

        # Check against 'disabled' regex; if matches, fail with error.
        if ($self->_apply_regexes($module_id)) {  # module is disabled
            $self->log->warn("module is disabled");
            $minion_job->fail("module is disabled");
            return 0;
        }

        $module_info->{relative_url} =~ m{/([^/]+?)\z};

        my $module_specific = $1;
        return 0 unless defined $module_specific;

        my $module = $module_info->{name};
        $self->log->info("Testing: (($module)) (($module_info->{version}))");  # TODO: Add minion job number

        # actually test the module

        # next two variable settings are explained in this link
        ### http://www.dagolden.com/index.php/2098/the-annotated-lancaster-consensus
        local $ENV{NONINTERACTIVE_TESTING} = 1;
        local $ENV{AUTOMATED_TESTING}      = 1;

        # Test the specific version we asked for
        # 'relative_url' will actually be full URI at this point
        my $tested_module = Mojo::URL->new($module_info->{relative_url});
        my $command;

        my ($build_log, $build_error_log);

        # XXX: Without the following, for some reason, Minion fails with
        # »DBD::SQLite::db prepare_cached failed: no such table: minion_jobs
        # at Minion/Backend/SQLite.pm line 287«
        $minion_job->note(build_log => undef,   # Remove any previous logs remaining when
                          error_log => undef,   # retrying a failed job
                         );

        # if (!defined $env_id) { # use currently installed version
        #     # $^V  Perl version as 'v5.26.0'
        #     $perlbuild_id = $self->my_environment();
        #     # NOTE: For possible later use.
        #     ($build_log, $build_error_log, $grade) = CPAN::Wrapper::run_test(join('/',
        #                                                                           $module_info->{author},
        #                                                                           $module_specific));
        # }
        # else {  # use Perlbrew
        my $pb = $self->sql->db->query('SELECT id, perlbrew FROM environments WHERE id=?',
                                       $env_id)->hashes;
        if (defined $pb) {
          $perlbuild = $pb->first->{perlbrew};
          $perlbuild_id = $pb->first->{id};
          $self->log->info("Using Perlbrew $perlbuild");
        } else {
          $self->log->error("Can't find Perlbrew environment with id=$env_id");
          $minion_job->fail("Can't find Perlbrew environment with id=$env_id");
          return 0;
        }

        my $result = TestModule::test_module( module => $module_info->{relative_url},
                                              perl_release => $perlbuild );
        # Save with a hash slice
        # NB: build_error_log is actually the result log
        ($build_log, $build_error_log, $grade) = @$result{qw(build_log report grade)};
        # }

        # XXX: If the ->note() method is not called above, this fails?
        $minion_job->note(build_log => $build_log,
                          result_log => $build_error_log,
                          grade => $grade,
                         );

        $minion_job->finish("Ran test for $tested_module");

        # Enqueue the report to be processed and sent later
        $self->minion->enqueue(report => [module => $module,
                                          module_id => $module_id,
                                          perlbuild => $perlbuild,
                                          grade => $grade,
                                          (defined $command) ? (command => $command) : (),
                                          tested_module => $tested_module,
                                          minion_job => $minion_job->info->{id},
                                         ]);

    }

    ################

    sub check_exit {
        my ($self, $exit, $what) = @_;
        if ( $exit == -1 ) {
            $self->log->error ("$what failed to execute: $!");
        } elsif ( $exit & 127 ) {
            $self->log->error( sprintf("$what child died with signal %d, %s coredump\n",
                                       ( $exit & 127 ), ( $exit & 128 ) ? 'with' : 'without'));
        } else {
            $self->log->info(sprintf("$what child exited with value %d\n", $exit >> 8));
        }
    }

    ################################################################

    sub apply {
        my ($self, $recipe_name) = @_;

        my @recipe_steps = eval { @{$self->config->{apply}->
                                    {$recipe_name // 'recent'} }
                              };

        # TODO: How do we choose the Perl version?

        foreach my $step (pairs( @recipe_steps)) {
            my ( $action, $args ) = @$step;
            if ($self->can($action)) {
                # Array refs [] get expanded to ordinary argument list; else verbatim
                # $module_group->$action(ref $args eq 'ARRAY' ? @{$args} : $args);
                # TODO: Need to handle errors and bail out
            }
        }
        # use $module_group->selected() ...?
    }


    ################
    
    sub _item_list {
        # Returns empty list (which gets skipped in building list later) if no author, -or-
        # {'term' => {'author' => 'JBERGER'}},  # single author passed
        # {'or' => [{'term' => {'author' => 'PREACTION'}},
        #           {'term' => {'author' => 'JBERGER'}}]}  # 'PREACTION,JBERGER' passed-in
        #
        my $option = shift;
        my @item_list;
        while (defined (my $item = shift)) {
            if (ref $item) {
                push @item_list, map { split /,/ } @{$item};
                next;
            }
            push @item_list, split (',', $item) if defined $item;
        }
        # XXX: Probably eliminate the special-case of ref and move that logic into _versions() below
        if (ref $option) { # Listref: [term, value to return if item is empty]
            if (!scalar @item_list) {
                return ${$option}[1];
            }
            $option = ${$option}[0];
        }
        return () unless scalar @item_list;
        return { term => { $option => $item_list[0] }} if (scalar @item_list == 1);
        return { term => { or => [ map { { term => { $option => $_ }} } @item_list ] } };
    }

    sub _date_range {
        my ($start, $end) = @_;
        if (defined $start && defined $end) {
            return ( range => { date => { gte => $start, lte => $end } } );
        }
        return ('match_all' => {});   # populate 'query' with this
    }

    sub _versions {
        my ($versions, $modules, $count) = @_;
        # TODO:
        # Return appropriate for these use cases
        # - get the one latest version (status=latest) of each of several modules
        # - get last 'n' versions of one module (use 'count')
        # - get specific versions of one module
        # ... _item_list(['version', {term => {'status' => 'latest'}}], $self->{versions}) ...

        # XXX: this won't work, because _item_list does more than just separate out comma-delimited lists
        my @selected_versions = _item_list($versions);
        return @selected_versions if scalar @selected_versions;
        # ...
    }

    sub test_metacpan {
        my ($self, @modules) = @_;   # Optionally specify one or more modules by name
        # See also: https://github.com/metacpan/metacpan-api/blob/master/docs/API-docs.md

        # TODO: Modify query below for named modules vs. whatever's-latest
        # https://fastapi.metacpan.org/v1/download_url/HTTP::Tiny
        # returns {status, version, date, download_url}

        my $ua = Mojo::UserAgent->new();
        my $source_url;
        my $hits=[];

        if (scalar @modules) {
            # Explicitly requesting modules, always forces their test.
            $self->{force_test} = 1;
            $source_url = $self->config->{metacpan}->{module};
            foreach my $module (@modules) {
                my $req_url = Mojo::URL->new($source_url);
                $req_url->path($req_url->path->trailing_slash(1)->merge($module));
                my $modules = $ua->get($req_url)->result;
                push @{$hits}, { fields => { %{$modules->json}, main_module => $module } } if defined ($modules);
            }
        } else {
            $source_url = $self->config->{metacpan}->{release}; # API endpoint;
            my $req = { 'size' => $self->{count} // 10,
                        'fields' => [qw(name version date author download_url main_module)],  # could add:  provides
                        'filter' => {'and' => [_item_list('main_module', $self->{modules}),
                                               _item_list('author', $self->{authors}),
                                               # TODO: Change this to _versions() above???
                                               _item_list(['version', {term => {'status' => 'latest'}}], $self->{versions}),
                                              ]},
                        'query' => { # optional range, otherwise 'all'
                                    _date_range( $self->{start_date}, $self->{end_date} ) },
                        'sort' => {'date' => 'desc'},
                      };
            # NOTE: $module->{fields}->{provides} if used, would contain a list of provided (sub)modules
            my $modules = $ua->post($source_url => json => $req)->result;
            my $module_list = defined ($modules) ? Mojo::JSON::decode_json($modules->body) : {};
            $hits = $module_list->{hits}->{hits};
        }

        ; $DB::single = 1;

        foreach my $module (@{$hits}) {
            my $id = eval {
                $self->sql->db->query('INSERT INTO modules(name, version, released, author, relative_url) '.
                                      'VALUES (?,?,?,?,?)',
                                      $module->{fields}->{main_module},
                                      @{$module->{fields}}{qw(version date author download_url)})
                ->last_insert_id;
            };
            $self->log->info('Adding ' . $module->{fields}->{main_module} . " = $id")
            if (defined $id && $self->{verbose});
            # For now, save full URL instead of relative.  Could do something like:
            # my $relative_url = Mojo::URL->new($module->{fields}->{download_url})->path;

            # Newly-seen modules are always tested. Can also force testing of old ones.
            if (!defined $id && $self->{force_test}) {
                $id = eval {
                    $self->sql->db->query('SELECT id FROM modules WHERE name=? AND version=?',
                                          $module->{fields}->{main_module},
                                          $module->{fields}->{version}
                                         )->hash->{id};
                };
                $self->log->info('Queue test for ' . $module->{fields}->{main_module} .' v' . $module->{fields}->{version}
                . " = $id (--force in effect)")
                if defined $id && $self->{verbose};
            }
            if (defined $id) {
                # enqueue Minion testing job
                # TODO: append Perl version for use with Perlbrew
                $self->minion->enqueue(test => [module_id => $id]);
            }
        }
    }


    sub cpan_recent {
        my ($self, @args) = @_;
    }

    sub yaml_regex {
        my ($self, @args) = @_;
    }

    sub released {
        my ($self, @args) = @_;
    }

    sub tested {
        my ($self, @args) = @_;
    }


};

1;
