package Smoketest::Command::update {
    use Mojo::Base 'Mojolicious::Command';
    use Mojo::Util qw(getopt);

    has 'description' => 'Retrieves distribution info from MetaCPAN. Enqueues tests.';

=pod

=head2 Update

=cut

    has usage => <<"=cut" =~ s/  APPLICATION/$0/rg =~ s/\s+=pod\s+//rs;

=pod

Usage: APPLICATION update [-v|--verbose] [-count=N] [-force] [-notest] [--distribution=DIST]
                          [--version=N.NN] [--release=N] [--author=N] [--perl_version=N]
                          [--start_date=YYYY-MM-DD] [--end_date=YYYY-MM-DD]

Retrieve a list of Perl module distributions from CPAN.

Examples:

Testing the latest 20 distributions:

    APPLICATION update --count=20

Testing the latest distributions from an author:

    APPLICATION update --count=5 --author=PREACTION

Testing the latest 20 distributions on two different Perl versions:

    APPLICATION update --count=20 --perl 5.26.1,5.24.1

or, equivalently,

    APPLICATION update --count 20 --perl 5.26.1 --perl 5.24.1

Testing a specific distribution:

    APPLICATION update --perl 5.26.1,5.24.1 Time::MockTime::HiRes

will enqueue two tests, one for each version of Perl given, on the
latest version of the Time::MockTime::HiRes distribution.  To re-test
this distribution after those tests complete, use the --force switch:

    APPLICATION update --perl 5.26.1,5.24.1 Time::MockTime::HiRes -f

=cut

    sub run {
        my ($self, @args) = @_;
        getopt \@args, [qw(auto_abbrev)],
          'v|verbose' => \my $verbose,   # Note abbrev, versus -version below
          'count=i' => \my $count,
          'force'   => \my $force_test,
          'notest'  => \my $skip_tests,
          'distribution|distro=s' => \my @dists,
          'version=s' => \my @versions,  # one 'Release' is a 'Distribution-Version' combination,
          'release=s' => \my @releases,  # so generally either specify release or distro(+version).
          'author=s' => \my @authors,
          'perl_version=s' => \my @perl_versions,
          'start_date=s' => \my $start_date,
          'end_date=s'   => \my $end_date;

        push @dists, @args;              # Remaining arguments are module names

        # Split/join to also permit comma-delimited
        my $releases =
          $self->app->smoker->get_metacpan( { count => $count,
                                              main_module => [split ',', join ',', @dists],
                                              name => [split ',', join ',', @releases],
                                              version => [split ',', join ',', @versions],
                                              author => [split ',', join ',', @authors],
                                              start_date => $start_date,
                                              end_date => $end_date,
                                            } );

        # Ensure updated list of installed Perl versions
        $self->app->smoker->update_perl_versions(@args);

        my @perl_test_versions;
        foreach my $v (split ',', join ',', @perl_versions) {
            # Look for Perlbrew name first, then Perl's self-reported version
            my $vv = $self->app->smoker->get_environment({perlbrew => $v}) //
                $self->app->smoker->get_environment({perl => $v});
            if (defined $vv) {
                push @perl_test_versions, $vv
            } else {
                die "Perl version ($v) not found";
            }
        }
        # Default to current environment
        if (!scalar @perl_test_versions) {
          @perl_test_versions = ($self->app->smoker->get_environment({id => $self->app->smoker->my_environment()}));
        }
        # Enqueue tests for each of those releases.
        my $added = 0;
        if (defined $releases && !$skip_tests) {
          $self->app->log->info('Considering ' . $releases->size . ' releases') if $verbose;
          $releases->each(sub {
                            my $id = $_->{id};
                            # TODO: Move below into separate routine
                            # TODO: Probably move enqueue() calls into Smoker
                            foreach my $v (@perl_test_versions) {
                                # XXX: ?+0 to work around DBD::SQLite issue; c.f.
                                # https://metacpan.org/pod/DBD::SQLite#Add-zero-to-make-it-a-number
                                my $skip;
                                if (!defined $force_test) {
                                    $skip = eval{$self->app->sql->db->query(q{SELECT id FROM minion_jobs WHERE }.
                                                                            q{(task='test') AND }.
                                                                            q{json_extract(args,'$[0].release_id')=?+0 }.
                                                                            q{AND json_extract(args,'$[0].environment')=?+0},
                                                                            $id, $v->{id})->hashes->first->{id}};
                                    $skip //= eval{$self->app->sql->db->select(-from => 'tests',
                                                                               -where => {release_id => $id,
                                                                                          environment_id => $v})
                                                   ->hashes->first->{id}};
                                    $skip = " (skipping, already tested)" if defined $skip;
                                }
                                $self->app->log->info('  ... ' . $_->{name} .
                                                      ' (Perl ' . ($v->{perlbrew} // $v->{perl}) . ')' .
                                                      ($skip//''))
                                  if $verbose;
                                if (!defined $skip) {
                                    $self->app->minion->enqueue(test => [{release_id => $id, environment => $v->{id}}],
                                                                {notes => {module_info => $_,
                                                                           perl_version => ($v->{perlbrew} // $v->{perl})
                                                                          }});
                                    $added++;
                                }
                            }
                        });
          $self->app->log->info("Releases added: $added");
      }

    }
};

1;
