use strict;
use warnings;

package CPAN::Wrapper {

    use Mojo::Base '-base';

    has 'log';
    has 'config';

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

    sub version {
        return $CPAN::VERSION;
    }

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
        my $result = $ua->get($source_url);
        if ($result->res->{code} == 200) {
            my $module_fields = $result->res->json;
            return $module_fields;
        }
        return undef;
    }

    ################

    sub disabled_regex_url {
      my ($self, $author, $version) = @_;
      my $source_url = Mojo::URL->new($self->config->{source});
      push @{$source_url->path->parts}, ( $author,
                                          'CPAN-' . $version,
                                          'distroprefs',
                                          $self->config->{disable} //
                                          '01.DISABLED.yml'
                                        );
      $source_url->path->trailing_slash(0);
      return $source_url;
    }

    sub recent_url {
      my ($self) = @_;
      my $source_url = Mojo::URL->new($self->app->config->{cpan}->{testers} );
      push @{$source_url->path->parts},
        'modules',
        $self->app->config->{cpan}->{recent} // '01modules.mtime.html';
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

    ################

    sub get_modules {
      my ($self, $source) = @_;

      my $module_list;
      my $module_dom;

      ; $DB::single = 1;

      # If no source specified, load default remote module list
      my $source_url = Mojo::URL->new($source // $self->config->{cpan_testers});
      if ($source_url->protocol || $source_url->host) { # Looks like a remote file
        unless (length($source_url->path) > 1) { # no path, or '/'
          push @{$source_url->path->parts}, ( 'modules',
                                              $self->config->{cpan}->{modules} //
                                              '02packages.details.txt'
                                            );
        }
        my $ua = Mojo::UserAgent->new();
        $module_list = $ua->get($source_url)->result;
        if ($module_list->is_success) {
          if ($source_url->path =~ /\.htm/) {
            $module_dom = $module_list->dom;
          } else {
            $module_list = $module_list->body; # plaintext contents
          }
        } else {
          $self->log->error("Can't download modules list: ".$module_list->message);
          return undef;
        }
      } else {                  # Local file
        $module_list = Mojo::File->new($source)->slurp;
        if (length($module_list)) {
          $module_dom = Mojo::DOM->new($module_list) if ($module_list =~ /<html/i);
        } else {
          $self->log->error("No module list file");
          return undef;
        }
      }

      my $module_tgzs;
      if (defined $module_dom) {
        $module_tgzs = _dom_extract($module_dom->find('a[href$=".tar.gz"]'));
      } else {
        $module_tgzs = _text_extract($module_list);
      }

      return $module_tgzs;
    }
    
    ################################################################

    use YAML;

    sub load_regex {
        my ($self, $source) = @_;

        # Retrieve a local or remote copy of a regex which will be
        # applied against the list of modules, and which will disable
        # (or enable) them.

        # If no source specified, load default remote file
        my $use_latest = defined $source;
        my $source_url = $use_latest ? Mojo::URL->new($source) : $self->disabled_regex_url;
        my ($disabled_list, $priority, $author, $version, $reason);

        if ($source_url->protocol || $source_url->host) { # looks like a URL
            if ($use_latest) {
                my $cpan_module = $self->get_cpan_module;
            
                ($author, $version) = @{$cpan_module}{qw(author version)};
                if ($version ne version()) {
                    $self->log->warn ("Our cpan=$CPAN::VERSION but remote is $version");
                }
                ($reason, $priority) = ("${author}/CPAN-${version}", 100); # Default for remote file
            } else {
                ($reason, $priority) = ($source, 100); # Save exact remote source.
                # TODO: What to store for Author, Version?
            }
            $self->log->info("Reading Module regex from $source");
            $disabled_list = Mojo::UserAgent->new()->get($source_url)->result;
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
                 author => $author,
                 disable => $matchfile->{disabled},
                 regex => $matchfile->{match}{distribution}
               };
    }




    # XXX: This was an alternate way to capture cpanm output.
    # use Capture::Tiny ':all';






};

1;
