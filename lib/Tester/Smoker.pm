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
            my $db = Mojo::SQLite->new('sqlite:' . $self->database);
            $db->abstract(SQL::Abstract::More->new());
            return $db;
        }
    };
    has 'config';
    has '_update_regex'; # Flag set when we find a new version of
                         # CPAN, to remind us to fetch and save the
                         # appropriate new regex

    use CPAN::Wrapper;
    has 'cpan' => sub {
        my ($self) = @_;
        my $cpan = CPAN::Wrapper->new(config => $self->config->{cpan},
                                  log => $self->log,
                                     );

        # Returns record for the latest CPAN version from our
        # database.  If none (e.g., empty database), or if different
        # from the CPAN we have, update our db with the latest release
        # info from metacpan.
        my $cpan_module = $self->get_release_info({name => 'CPAN'})->first;
        if ((!defined $cpan_module) || ($cpan_module->{version} ne $cpan->version)) {
            # NOTE: We cannot use $self->update_module() here, because
            # that depends on the $self->cpan object, which we haven't
            # defined yet.
            $cpan_module = $cpan->get_module_info('CPAN','release');   # Fetch latest version from metacpan
            if (defined $cpan_module) {
                $cpan_module->{_db_id} = $self->save_release_info($cpan_module);  # keep new id value
                $self->_update_regex(1);
            }
        }
        if (defined $cpan_module && ($cpan->version ne $cpan_module->{version})) {
            ### NOTE: As of 2017-11-20, Perlbrew install cpan version
            ### 2.18 but metacpan says latest is 2.16.  This is
            ### probably not harmful, but ideally these should
            ### match. This condition forces the above code to ask
            ### metacpan during initialization of each web instance or
            ### worker.
            $self->log->warn ("Our cpan=". $cpan->version ." but remote is ". $cpan_module->{version});
        }

        $cpan->current_cpan({%{$cpan_module}{qw(version author)}}); # Completes the cpan object's attributes
        return $cpan;
    };

    sub new {
        my $class = shift;
        my $self = $class->SUPER::new(@_);

        $self->sql->migrations->name('smoker_migrations')->
          from_file('sqlite_migrations');

        $self->sql->migrations->tap(sub { $self->rebuild and $_->migrate(0) })->migrate;
        my $jmode = $self->sql->db->query('PRAGMA journal_mode=WAL;');
        if ($jmode->arrays->[0]->[0] ne 'wal') {
            warn 'Note: Write-ahead mode not enabled';
        }
        $self->sql->db->query('PRAGMA foreign_keys=1;');
        
        return $self;
    }

    use Sys::Hostname;        # hostname() returns our fqdn, if available
    use Config;

    sub my_environment {
        # Returns the id of our native (non-Perlbrew) environment, adding it if required
        my $self = shift;

        # ; $DB::single = 1;
        my $my_config = {host => hostname(),
                         %Config{qw(osname osvers archname)},  # hash slice
                         perl => $Config{version},
                        };
        my $env = eval { $self->sql->db->select(-from => 'environments',
                                                -columns => ['id'],
                                                -where => $my_config)->hashes; };
        if (defined $env && $env->size) {
            return $env->first->{id};
        } else {
            return $self->sql->db->insert(-into => 'environments',
                                          -values => $my_config)->last_insert_id;
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
                    my $version_specific = `perlbrew exec --with $v perl -MConfig -MSys::Hostname -e 'print join("\n", %Config{qw(osname osvers version archname)})'`;
                    # returns, e.g.:  (perl-5.24.1)\n===...===\n and results
                    if ($version_specific =~ /===\s+(.*?)\s*\z/s) {
                        my $version_info = {split /\n/, $1};
                        eval {
                            $self->sql->db->query('UPDATE environments '.
                                                  'SET osname=?, osvers=?, perl=?, archname=? WHERE id=?',
                                                  $version_info->@{qw(osname osvers version archname)}, # hash slice
                                                  $id
                                                 );
                        };
                    }
                }
            }
        }
    }

    ################################################################

    sub fetch_and_save_regex {
        # Save to the database, a local or remote copy of a regex
        # which will be applied against the list of modules, and which
        # will disable (or enable) them.
        my ($self, $source) = @_;

        my $regex = $self->cpan->load_regex($source);
        if (defined $regex) {
          my $saved = $self->sql->db->query('INSERT OR REPLACE INTO module_flags (priority, origin, author, disable, regex) '.
                                            'VALUES (?,?,?,?,?)',
                                            @{$regex}{qw(priority reason author disable regex)}
                                           );
          return 1;
        }
        return undef;
    }

    sub load_regexes {
        my ($self) = @_; 

        # For each available enable/disable list, prepare to apply in priority order
        my $regex_list = eval{
            $self->sql->db->select(-from => 'module_flags',
                                   -order_by => [{-desc => 'priority'}, {-desc => 'added'}],
                                  )->hashes;
        };
        return undef if ( (!defined $regex_list) || ($regex_list->size ==0));
        return $regex_list;
    }

    ################################################################

    sub _check_regexes {
        # Apply, in priority order, all defined regular expressions
        # which could enable or disable the selected module.  Set
        # disabled_by in the module database accordingly.
        my ($self, $module_id) = @_; 

        # For each available enable/disable list, prepare to apply in priority order
        my $regex_list = $self->load_regexes;
        if (!defined $regex_list || $self->_update_regex) {
            if ($self->fetch_and_save_regex()) {   # Retrieve regex from default source
                $regex_list = $self->load_regexes; # and reload from database
                $self->_update_regex(0);
            } else {
                $self->log->error("Failed to retrieve regex");
            }
        }
        return undef unless defined $regex_list;

        my $module_info = eval {
            $self->sql->db->select(-from => 'releases',
                                   -where => {id => {-in => $module_id}},
                                   # ok for scalar or arrayref
                                  )->hashes;
        };
        return undef unless defined $module_info;

        # ; $DB::single = 1;
        $module_info->each( sub {
                              my $module_id = $_->{id};
                              my $regex_match = join('/', $_->{author}, $_->{name});
                              my $disabled_by;
                              $regex_list->each(sub {
                                                  my $against = $_->{regex};
                                                  $against =~ s/\|\s*\z//;  # Remove any trailing pipe
                                                  if ($regex_match =~ $against) {
                                                    if ($_->{disable}) {
                                                      $disabled_by = $_->{origin};
                                                    } else {
                                                      undef $disabled_by; # enable
                                                    }
                                                  }
                                                });
                              # Save final enabled/disabled status
                              eval { $self->sql->db->update(-table => 'releases',
                                                            -set => { disabled_by => $disabled_by },
                                                            -where => { id => $module_id });
                                     $self->log->info("Module $_->{name} disabled by regex")
                                       if defined $disabled_by;
                                   };
                            } );
        return 1;
    }

    sub check_regex {
        my $self = shift;
        my $args = {@_};

        if (ref $args->{release_id} eq 'Mojo::Collection') { # Flatten into array of id values
            $args->{release_id} = $args->{module_id}->map(sub {$_->{id}})->to_array;
        }
        return $self->_check_regexes($args->{release_id});   # scalar or arrayref OK
    }

    sub release_disabled_by {
        my ($self, $release_id) = @_;
        $self->check_regex(release_id => $release_id);
        my $check = eval {
          $self->sql->db->select(-from => 'releases',
                                 -columns => 'disabled_by',
                                 -where => {id => $release_id})->hashes->first;
        };
        return defined $check ? $check->{disabled_by} : undef;
    }

    ################################################################

    sub get_environment {
      # Retrieves the latest information for a module
      # TODO: rename to get_release_info
      my ($self, $where) = @_;
      my $results = eval {
        $self->sql->db->select(-from => 'environments',
                               -where => $where,
                               -limit => 1,
                              )->hashes->first;
      };
      return $results;
    }

    ################################################################

    sub get_release_info {
      # Retrieves the latest information for a module
      # TODO: rename to get_release_info
      my ($self, $where, $limit) = @_;
      my $results = eval {
        $self->sql->db->select(-from => 'releases',
                               -where => $where,
                               -limit => $limit // 1,
                               -order_by => ['-released'])->hashes;
      };
      return $results;
    }

    ################

    sub save_release_info {
      # TODO: rename to save_release_info
        my ($self, $fields) = @_;

        # results from /release have a 'main_module';
        # with results from /module we use the name of the first (only?) module
        my $module_name = eval { $fields->{module}->[0]->{name}; } // $fields->{main_module};
        return undef unless defined $module_name;
        my $id = eval {
                $self->sql->db->query('INSERT INTO modules(name, version, released, author, download_url) '.
                                      'VALUES (?,?,?,?,?)',
                                      $module_name,
                                      @{$fields}{qw(version date author download_url)})
                ->last_insert_id;
            };
        return $id;
    }

    sub update_module {
        # Retrieves, from metacpan, the information about the latest version of the module or release
        # Returns the database id if we created a new record for an updated module; undef otherwise.
        my ($self, $module_name, $type) = @_;  # optionally, type='release'

        my $module_fields = $self->cpan->get_module_info($module_name, $type);
        if (defined $module_fields) {
            $module_fields->{_db_id} = $self->save_release_info($module_fields);  # keep new id value
        }
        return $module_fields;
    }

    ################################################################

    sub save_releases {
        my ($self, $releases) = @_;

        if (defined $releases) {
            $releases->each(sub {
                                $_->{id} = eval {$self->sql->db->insert(-into => 'releases',
                                                                        -values => {%$_{qw(name version
                                                                                           released author
                                                                                           download_url)}},
                                                                       )->last_insert_id;
                                             };
                                if (!defined $_->{id}) {  # Probably already existed
                                    $_->{id} = eval { my $g = $self->sql->db->select(-from => 'releases',
                                                                                     -where => {%$_{qw(name version)}});
                                                      $g->hashes->first->{id};
                                                  };
                                }
                            });
            $self->log->info("got updated release list");
        }
        return $releases;
    }

    sub update {
        my ($self, $source) = @_;

        # Get a list of releases from the source URL
        return save_releases($self->cpan->get_modules($source));
    }

    sub get_recent {
        # Get the list of most recently updated modules from source; default to
        # http://cpan.org/modules/01modules.mtime.html
        # NOTE: the caller will probably create a Minion job to test each
        my ($self, $source) = @_;
        return $self->update($self->cpan->module_list_url('recent', $source));
    }

    sub get_all {
        # Get the list of all modules from source
        # NOTE: the caller will probably create a Minion job to test each
        my ($self, $source) = @_;
        return $self->update($self->cpan->module_list_url('all', $source));
    }

    sub get_metacpan {
        my ($self, $args) = @_;
        return $self->save_releases(Mojo::Collection->new($self->cpan->get_metacpan($args)));
    }

    ################################################################
    ###
    ### (Mothballed)
    ### Currently unused, these pick releases from our database
    ### versus asking MetaCPAN.
    ###

    sub _pick {
      # Similar to the hash slice, » $hash->%{@elements} «
      # but only picks defined entries.
      my ($hash, @elements) = @_;
      return map { exists $hash->{$_} ? ( $_, $hash->{$_} ) : () } @elements;
    }

    sub _add_test {
      # Run a test on a given release (module+version), on a given
      # version of Perl
      my ($self, $mod_info) = @_;
    
      my $release_id = $mod_info->{dist_id} // eval {
        # Because of the index `dist_idx`, choosing the most-recent
        # distribution by name will always give us the latest version

        # TODO: use $self->get_module_info() instead of db query here
        $self->app->db->select( -from => 'releases',
                                -columns => ['id'],
                                -where => { _pick ( $mod_info,
                                                    qw(name version) ) },
                                -order_by => ['-added'],
                                -limit => 1 )->hash->{id};
      };
      $self->smoker->minion->enqueue('test', [{ dist_id => $release_id,
                                               env_id => $mod_info->{environment_id}
                                             }], { notes => {module_info => $mod_info}});
    }

    sub _find_recent {
      my ($self, $mod_info, $limit) = @_;

      # example of passing more complex queries to _find_recent:
      #   _find_recent($self,{author =>'ANDK', name => {'LIKE', 'CPAN%'}})
      #   _find_recent($self,{added => {'>',\["datetime('now', ?)", '-21 day']}})

      my $releases =
        $self->app->db->select( -from => 'releases',
                                # grouping by name after selecting max(added)
                                # guarantees we get the most-recently-added version
                                # for each module name
                                -columns => ['id', 'name', 'max(added) as added'],
                                -where => { _pick ( $mod_info,
                                                    qw(name version author added) ),
                                            disabled_by => undef, # not disabled
                                          },
                                -group_by => ['name'],
                                -order_by => ['-added'], # most-recent first
                                (defined $limit) ? (-limit => $limit) : (),
                              );
      return $releases->hashes; # as a Mojo::Collection
    }

    sub _find_recent_days {
      my ($self, $day_count, $limit) = @_;
      return _find_recent($self,{added => {'>',\["datetime('now', ?)", -$day_count.' days']}}, $limit);
    }

    ###
    ### End mothballed section
    ###
    ################################################################

    use TestModule;

    sub test {
        my $self = shift;
        my $minion_job = shift;
        my $args = {@_};

        my $release_id = $args->{release_id};
        my $env_id = $args->{environment};
        my $perlbuild;
        my $grade;

        if (! $release_id) {
            $self->log->error("No module_id");
            return 0;
        }

        my $module_info = $self->sql->db->select(-from => 'releases',
                                                 -where => {id => $release_id}
                                                )->hashes;
        return 0 unless defined $module_info;
        $module_info = $module_info->first;

        # Check against 'disabled' regex; if matches, fail with error.
        my $dis_by = $self->release_disabled_by($release_id);
        if ($dis_by) {  # module is disabled
            $self->log->warn("module is disabled by $dis_by");
            $minion_job->fail("module is disabled by $dis_by");
            return 0;
        }

        $self->log->info("Testing: $module_info->{name} version $module_info->{version}");

        # actually test the module

        # next two variable settings are explained in this link
        ### http://www.dagolden.com/index.php/2098/the-annotated-lancaster-consensus
        local $ENV{NONINTERACTIVE_TESTING} = 1;
        local $ENV{AUTOMATED_TESTING}      = 1;

        # Test the specific version we asked for
        my $tested_module = Mojo::URL->new($module_info->{download_url});
        my $command;

        my ($build_log, $build_error_log);

        # XXX: Without the following, for some reason, Minion fails with
        # »DBD::SQLite::db prepare_cached failed: no such table: minion_jobs
        # at Minion/Backend/SQLite.pm line 287«
        $minion_job->note(build_log => undef,   # Remove any previous logs remaining when
                          error_log => undef,   # retrying a failed job
                         );

        # Choose a (Perlbrew) environment, or use the current (system, or other) Perl
        if (!defined $env_id) { # use currently installed version
             $env_id = $self->my_environment();
        }
        # Describe that environment
        my $pb = eval { $self->sql->db->select(-from => 'environments',
                                               -where => {id => $env_id})->hashes->first; };
        if (defined $pb) {
            $self->log->info("Using Perl version ".$pb->{version}.", Perlbrew installation ".$pb->{perlbrew});
        } else {
            $self->log->error("Can't find environment (id=$env_id)");
            $minion_job->fail("Can't find environment (id=$env_id)");
            return 0;
        }

        my $result = TestModule::test_module({module => $module_info->{download_url},
                                              perl_release => $perlbuild
                                             });

        # XXX: If the ->note() method is not called above, this fails?
        foreach (qw(build_log report grade test_exit reporter_exit)) {
            $minion_job->note($_ => $result->{$_});
        }
        $self->log->info("Ran test for $tested_module");
        $minion_job->finish("Ran test for $tested_module");

        # Enqueue the report to be processed and sent later
        $self->log->info("enqueueing Report");
        $minion_job->minion->enqueue(report => [{release => $module_info->{name},
                                                 release_id => $release_id,
                                                 # hash slice of environment:
                                                 %{$pb}{qw(host perlbrew platform perl osname osvers)},
                                                 environment => $env_id,
                                                 grade => $result->{grade},
                                                 (defined $command) ? (command => $command) : (),
                                                 tested_module => $tested_module,
                                                 minion_job => $minion_job->info->{id},
                                                }
                                               ],
                                     { parents => [$minion_job->info->{id}],
                                     });
        $self->log->info("Report enqueued");
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

};

1;
