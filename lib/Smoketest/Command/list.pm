package Smoketest::Command::list {
    use Mojo::Base 'Mojolicious::Command';
    use Minion::Backend;
    use Mojo::Util qw(getopt);

    has 'description' => 'List currently-enqueued tests to be run';

=pod

=head2 List

=cut

    has usage => <<"=cut" =~ s/  APPLICATION/$0/rg =~ s/\s+=pod\s+//rs;

=pod

Usage: APPLICATION list [state] [-count N] [-reports]

Lists jobs in state (inactive (*), finished, failed) (*) default

To display enqueued jobs:

    APPLICATION list

To display completed jobs:

    APPLICATION list finished

To display a list of enqueued test report submissions for completed
jobs (reports have different IDs than jobs):

    APPLICATION list -r

To list submitted test reports, see:

    APPLICATION report -l

Then to display the actual report, do:

    APPLICATION report TEST_ID

=cut

    sub run {
        my ($self, @args) = @_;

        getopt \@args, [qw(auto_abbrev)],
        'count=i' => \my $count,
        'report'  => \my $show_defer,
          ;


        my $job_state = $args[0] // 'inactive';    # 'finished' or 'failed' are useful
        my $jobs = $self->app->minion->backend->list_jobs(0, $count // 50,  # offset, limit
                                                          {state => $job_state,
                                                           task => ($show_defer ? 'report' : 'test'),
                                                           $show_defer ? (queue => 'deferred') : (),
                                                          }
                                                         );
        if ($show_defer) {
            # Show queued report jobs which are held for manual release
            # TODO: Combine with 'unfinished' tablify below
            print Mojo::Util::tablify [ [qw/Job Status Test_ID Distribution Version Perl Grade/],
                                        map {
                                            my $release_id = eval{$_->{args}->[0]->{'release_id'}};
                                            if (defined $release_id) {
                                                my $info = $self->app->smoker->get_release_info({id => $release_id}) if defined $release_id;
                                                if (!defined $info || !$info->size) {
                                                    ()
                                                } else {
                                                    [ $_->{id}, $_->{state},
                                                      eval{$_->{args}->[0]->{test_id}} // '',
                                                      $info->first->@{qw/name version/},
                                                      $_->{notes}->{perl_version} // '',
                                                      eval{$_->{args}->[0]->{grade}} // '(unknown)',
                                                    ]
                                                }
                                            } else {
                                                ()
                                            }
                                        }
                                        @{$jobs->{jobs}} ];
        } else {
            if ($job_state eq 'finished') {
                print Mojo::Util::tablify [ [qw/Job Perl Result/],
                                            map {
                                                [ $_->{id}, $_->{notes}->{perl_version},
                                                  $_->{result}
                                                ]
                                            }
                                            @{$jobs->{jobs}} ];
            } else { 
                print Mojo::Util::tablify [ [qw/Job Status Distribution Version Author Perl/],
                                            map {
                                                my $release_id = eval{$_->{args}->[0]->{'release_id'}};
                                                if (defined $release_id) {
                                                    my $info = $self->app->smoker->get_release_info({id => $release_id}) if defined $release_id;
                                                    if (!defined $info || !$info->size) {
                                                        ()
                                                    } else {
                                                        [ $_->{id}, $_->{state},
                                                          $info->first->@{qw/name version author/},
                                                          $_->{notes}->{perl_version} // '',
                                                        ]
                                                    }
                                                } else {
                                                    ()
                                                }
                                            }
                                            @{$jobs->{jobs}} ];
            }
        }
        return;
    }
};

1;
