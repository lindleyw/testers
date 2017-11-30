use strict;
use warnings;

package CPAN::Wrapper {

    use Mojo::Base '-base';

    has 'log';
    has 'config';
    has 'current_cpan';  # Author and version of latest CPAN we know about

    ### NOTE: This module must be installed on all candidate Perlbrew
    ### installations so we can locate the various log files
    use App::cpanminus::reporter;

    has 'build_dir' => sub {
      App::cpanminus::reporter->new->build_dir;
    };

    # A wrapper module for CPAN testing and reporting
    #
    # TODO: Possibly release this as an official module, perhaps under
    # https://metacpan.org/pod/CPAN::Testers

    use CPAN;           # Must be inside a module, not the main
                        # program, because we don't want to *run*
                        # cpan!

    sub version {       # As installed on this system
        return $CPAN::VERSION;
    }

    use CPAN::Reporter::History;
    # NOTE: have_tested() returns a list of hashes, e.g.,
    # 0  HASH(0x4070958)
    #    'archname' => 'x86_64-linux'
    #    'dist' => 'Acme-CPAN-Testers-FAIL-0.02'
    #    'grade' => 'FAIL'
    #    'osvers' => '4.4.0-63-generic'
    #    'perl' => '5.26.0'
    #    'phase' => 'test'
    # You can optionally pass one or more key/value pairs to match against.

    if (0) {
    # # TODO:
    # # Consider this code from App::cpanminus::reporter --
    #   my $cpanm_version = $self->{_cpanminus_version} || 'unknown cpanm version';
    #   my $meta = $self->get_meta_for( $dist );
    #   my $client = CPAN::Testers::Common::Client->new(
    #                                                   author      => $self->author,
    #                                                   distname    => $dist,
    #                                                   grade       => $result,
    #                                                   via         => "App::cpanminus::reporter $VERSION ($cpanm_version)",
    #                                                   test_output => join( '', @test_output ),
    #                                                   prereqs     => ($meta && ref $meta) ? $meta->{prereqs} : undef,
    #                                                  );

    #   if (!$self->skip_history && $client->is_duplicate) {
    #     print "($resource, $author, $dist, $result) was already sent. Skipping...\n"
    #       if $self->verbose;
    #     return;
    #   } else {
    #     print "sending: ($resource, $author, $dist, $result)\n" unless $self->quiet;
    #   }

    #   my $reporter = Test::Reporter->new(
    #                                      transport      => $self->config->transport_name,
    #                                      transport_args => $self->config->transport_args,
    #                                      grade          => $client->grade,
    #                                      distribution   => $dist,
    #                                      distfile       => $self->distfile,
    #                                      from           => $self->config->email_from,
    #                                      comments       => $client->email,
    #                                      via            => $client->via,
    #                                     );
      # if ($self->dry_run) {
      #   print "not sending (drun run)\n" unless $self->quiet;
      #   return;
      # }

      # try {
      #   $reporter->send() || die $reporter->errstr();
      # }
      #   catch {
      #     print "Error while sending this report, continuing with the next one...\n" unless $self->quiet;
      #     print "DEBUG: @_" if $self->verbose;
      #   } finally{
      #     $client->record_history unless $self->skip_history;
      #   };

    }





    ################################################################
    #
    # To explore the MetaCPAN API, see: https://explorer.metacpan.org/
    #

    # NOTE:  Possibly for later use, given further CPAN refactoring
    # 
    # sub run_test {
    #     # Use the CPAN Shell function to actually run a test.
    #     # Return the stdout and stderr logs.
    #     # NOTE: CPAN::Shell->test(...) calls its function rematein(...) which
    #     # does not return any useful value.
    #     my @args = @_;
    #     my ($stdout, $stderr, @result) = eval { capture { CPAN::Shell->test ( @args ) } };
    #     return ($stdout, $stderr);
    # }

    sub get_module_info {
        # Get metacpan information for a module, or for a release (type='release')
        my ($self, $module_name, $type) = @_;

        my $ua = Mojo::UserAgent->new();
        my $source_url = Mojo::URL->new($self->config->{metacpan}->{$type // 'module'}); # API endpoint
        push @{$source_url->path->parts}, $module_name;
        my $result = eval { $ua->max_redirects(5)->get($source_url); };
        if (defined $result && $result->res->{code} == 200) {
            my $module_fields = $result->res->json;
            return $module_fields;
        }
        return undef;
    }

    ################

    sub disabled_regex_url {
      my ($self) = @_;
      my $source_url = Mojo::URL->new($self->config->{source});
      return undef unless defined $self->current_cpan;
      push @{$source_url->path->parts}, ( $self->current_cpan->{author},
                                          'CPAN-' . $self->current_cpan->{version},
                                          'distroprefs',
                                          $self->config->{disable} //
                                          '01.DISABLED.yml'
                                        );
      $source_url->path->trailing_slash(0);
      return $source_url;
    }

    my $default_list_url = {recent => '01modules.mtime.html',
                            all    => '02packages.details.txt'};

    sub module_list_url {
        my ($self, $which_list) = @_;  # which_list should be 'recent' or 'all'
        my $source_url = Mojo::URL->new($self->config->{testers} );
        push @{$source_url->path->parts},
          'modules',
          $self->config->{$which_list} // $default_list_url->{$which_list};
        return $source_url;
    }

    ################################################################

    # NOTE: This simple array serves as a substitute for the much-heavier:
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

    ################
    ### NOTE: The below subroutine and its helper are a much
    ### lighter-weight alternative to Parse::CPAN::Packages (which
    ### needs Moose and a whole host of other things).

    sub _text_line_extract {
        my ($module_text) = @_;
        
        my $vals = {};          # populate with a hash slice:
        @{$vals}{qw(name version download_url)} = split /\s+/, $module_text;
        $vals->{author} = ($vals->{download_url} =~ m{^./../(\w+)/})[0];
        $vals->{version} = undef if ($vals->{version} eq 'undef'); # Replace text 'undef'
        return $vals;
    }

    sub _text_extract {
        my ($module_text_list) = @_;
      
        # Extract from text file, skipping header, with header/body as SMTP message.

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

    ################

    sub get_modules {
      my ($self, $source) = @_;

      my $module_list;
      my $module_dom;

      # ; $DB::single = 1;

      # If no source specified, load default remote module list
      my $source_url = Mojo::URL->new($source // $self->config->{testers});
      if ($source_url->protocol || $source_url->host) { # Looks like a remote file
          unless (length($source_url->path) > 1) { # no path, or '/'
              push @{$source_url->path->parts}, ( 'modules',
                                                  $self->config->{all} //
                                                  '02packages.details.txt'
                                                );
          }
          my $ua = Mojo::UserAgent->new();
          $module_list = eval { $ua->max_redirects(5)->get($source_url)->result; };
          ; $DB::single = 1;
          if (defined $module_list) {
              if ($module_list->is_success) {
                  if ($source_url->path =~ /\.htm/) {
                      $module_dom = $module_list->dom;
                  } else {
                      $module_list = $module_list->body; # plaintext contents
                  }
                  $self->log->info("Fetched remote module list.");
              } else {
                  $self->log->error("Can't download modules list: ".$module_list->message);
                  return undef;
              }
          } else {
              $self->log->error("Can't download modules list: ".$@);
              return undef;
          }
      } else {                # Local file
          $module_list = Mojo::File->new($source)->slurp;
          if (length($module_list)) {
              $module_dom = Mojo::DOM->new($module_list) if ($module_list =~ /<html/i);
          } else {
              $self->log->error("No module list file");
              return undef;
          }
      }

      my $module_tgzs;
      ; $DB::single = 1;
      if (defined $module_dom) {
        $module_tgzs = _dom_extract($module_dom->find('a[href$=".tar.gz"]'));
      } else {
        $module_tgzs = _text_extract($module_list);
      }

      return $module_tgzs;
    }
    
    ################
    ###
    ### TODO: Move _item_list, _date_range, _versions and test_metacpan into here
    ### and make the return value parallel to _{text|dom}_extract().  Then we can
    ### call get_metacpan() for the metacpan API equivalently to get_modules().
    ###

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
        return { or => [ map { { term => { $option => $_ }} } @item_list ] };
    }

    sub _date_range {
        my ($start, $end) = @_;
        if (defined $start && defined $end) {
            return ( range => { date => { gte => $start, lte => $end } } );
        }
        return ('match_all' => {});   # populate 'query' with this
    }

    ### TODO: 
    ### Are we parsing the returned value equivalently to get_modules() --?

    sub get_metacpan {
        my ($self, $args) = @_;   # Optionally specify one or more modules by name
        # See also: https://github.com/metacpan/metacpan-api/blob/master/docs/API-docs.md

        my $ua = Mojo::UserAgent->new();
        my $source_url;
        my $hits=[];


        $source_url = $self->config->{metacpan}->{release}; # API endpoint;
        # NOTE: For a Release,
        # 'main_module' (e.g., 'Mojolicious') is the name of a Distribution
        # 'name'  (e.g., 'Mojolicious-7.46') is the full release name+version.
        my $req = { 'size' => $args->{count} // 10,
                    'fields' => [qw(name version date author download_url main_module)],  # could add:  provides
                    'filter' => {'and' => [_item_list('main_module', $args->{dist}), # e.g., 'Mojolicious'
                                           _item_list('name', $args->{release}),     # e.g., 'Mojolicious-7.46'
                                           _item_list('author', $args->{author}),
                                           _item_list(['version', {term => {'status' => 'latest'}}], $args->{version}),
                                          ]},
                    'query' => { # optional range, otherwise 'all'
                                _date_range( $args->{start_date}, $args->{end_date} ) },
                    'sort' => {'date' => 'desc'},
                  };
        # NOTE: Above could request $module->{fields}->{provides}
        # which would contain a list of provided (sub)modules

        print STDERR Mojo::JSON::encode_json($req);
        my $modules = $ua->post($source_url => json => $req)->result;
        my $module_list = defined ($modules) ? Mojo::JSON::decode_json($modules->body) : {};

        # NOTE: $module_list is now a list of hashes, as:
        # $VAR1 = \[
        #     {
        #       'sort' => [
        #                   '1510839207000'
        #                 ],
        #       '_type' => 'release',
        #       '_score' => undef,
        #       '_id' => 'cjj8Kp6m1KlG0CnLmtVVxWSVfFU',
        #       '_index' => 'cpan_v1_01',
        #       'fields' => {
        #                     'version' => '7.56',
        #                     'date' => '2017-11-16T13:33:27',
        #                     'author' => 'SRI',
        #                     'download_url' => 'https://cpan.metacpan.org/authors/id/S/SR/SRI/Mojolicious-7.56.tar.gz',
        #                     'main_module' => 'Mojolicious',
        #                     'name' => 'Mojolicious-7.56'
        #                   }
        #     }
        #   ];
        # and we want a list of just the fields hashes.
        return map { $_->{fields} } @{$module_list->{hits}->{hits}};
    }

    ################################################################

    use YAML;

    sub load_regex {
        my ($self, $source) = @_;

        # Retrieve a local or remote copy of a regex which will be
        # applied against the list of modules, and which will disable
        # (or enable) them.

        # If no source specified, load default remote file
        my $use_latest = !defined $source;

        ###
        ###  XXXX: ERROR:  disable_regex_url() requires author, version ... where to get from?
        ###  how does this work w/r/t Smoker::get_cpan_module (from database etc)
        ###
        my $source_url = $use_latest ? $self->disabled_regex_url : Mojo::URL->new($source);
        my ($disabled_list, $priority, $author, $reason);

        # ; $DB::single = 1;

        if ($source_url->protocol || $source_url->host) { # looks like a URL
            if ($use_latest) {
                my $cpan = $self->current_cpan;
                if (!defined $cpan) {
                    $self->log->error("Can't find current CPAN for regex");
                    return undef;
                }
                $source = $self->disabled_regex_url();
                if (!defined $source) {
                    $self->log->error("Can't load CPAN regex URL");
                    return undef;
                }
                $source_url = Mojo::URL->new($source);
                $reason = $cpan->{author} . '/CPAN-' . $cpan->{version};
                $priority = 100;

                if ($cpan->{version} ne version()) {
                    $self->log->warn ("Our cpan=".version()." but remote is ". $cpan->{version});
                }
            } else {
                ($reason, $priority) = ($source, 100); # Save exact remote source.
                # TODO: What to store for Author, Version?
            }
            $self->log->info("Reading Module regex from $source");
            $disabled_list = Mojo::UserAgent->new()->max_redirects(5)->get($source_url)->result;
            unless ($disabled_list->is_success) {
                $self->log->warn("Can't download regex: ".$disabled_list->message);
                return undef;
            }
            $disabled_list = $disabled_list->body;
        } else {
            # Local file
            ($reason, $priority) = ($source, 50); # Default for local
            unless (-r $source) {
                $self->log->error("Cannot read regex file: $source");
                return undef;
            }
            $disabled_list = Mojo::File->new($source)->slurp;
            unless (length($disabled_list)) {
                $self->log->error("Module list file ($source) is empty?");
                return undef;
            }
        }

        # Decode and save as meta-information in the Modules list
        my $matchfile = eval{YAML::Load($disabled_list)};
        if (!defined $matchfile) {
            $self->log->error("Cannot decode YAML: $@");
            return undef;
        }
        return { priority => $priority,
                 reason => $reason,
                 disable => $matchfile->{disabled},
                 regex => $matchfile->{match}{distribution}
               };
    }




    # XXX: This was an alternate way to capture cpanm output.
    # use Capture::Tiny ':all';






};

1;
