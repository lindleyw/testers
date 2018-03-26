package Smoketest::Command::report {
    use Mojo::Base 'Mojolicious::Command';
    use Mojo::Util qw(getopt);

    has 'description' => 'Displays the build log for the given report ID number';

=pod

=head2 Report

=cut

    has usage => <<"=cut" =~ s/  APPLICATION/$0/rg =~ s/\s+=pod\s+//rs;

=pod

To display the report which would be submitted for a completed test,
by Test ID:

    APPLICATION report 17

To display other data about a completed test, by ID:

    APPLICATION report 17 build_log
    APPLICATION report 17 test_error    # the STDERR log
    APPLICATION report 17 grade
    APPLICATION report 17 elapsed_time

To display the last several reports (defaults to 50):

    APPLICATION report -l [-count 50] [dist_name]

=cut

    sub run {

        my ($self, @args) = @_;
        getopt \@args, [qw(auto_abbrev)],
          'list' => \my $list,
          'count=i' => \my $count,
          ;
        my ($id, $what) = @args;  # remaining arguments

        if ($list) {   # optional value ($id) is a distribution name
            my $reports = $self->app->smoker->reports_for_name($id, $count);
            if (defined $reports && scalar @{$reports}) {
                print Mojo::Util::tablify [ [qw/Report_ID Distribution Version Release_Date Perl Runtime Grade Sent/],
                                        map {
                                            my $info = $self->app->smoker->get_release_info({id => $_->{release_id}});
                                            if (!defined $info || !$info->size) {
                                                ()
                                            } else {
                                                [ $_->{id},
                                                  $info->first->@{qw/name version released/},
                                                  $_->{notes}->{perl_version} // '',
                                                  sprintf('%8.2f',$_->{elapsed_time}),
                                                  eval{$_->{grade}} // '(unknown)',
                                                  defined $_->{report_sent} ? 'Yes' : ' - ',
                                                ]
                                            }
                                        }
                                            @{$reports} ];
            }
            return;
        }

        die "Must specify report ID" unless defined $id;

        my $result = $self->app->smoker->report_for($id);
        if (defined $result) {
            print ((eval{$result->{$what // 'report'}} // '(undefined)')."\n");
        } else {
            print "No test result found for id=$id\n";
        }
    }
};

1;
