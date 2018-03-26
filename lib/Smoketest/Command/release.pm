package main::Command::release {
    use Mojo::Base 'Mojolicious::Command';
    use Minion::Backend;
    use Mojo::Util qw(getopt);

    has 'description' => 'Release a currently-enqueued report';

=pod

=head2 Release

=cut

    has usage => <<"=cut" =~ s/  APPLICATION/$0/rg =~ s/\s+=pod\s+//rs;

=pod

Usage: APPLICATION release [IDS] [-count N]

Releases one or more report jobs by ID, or from newest by count
=cut

    sub run {
        my ($self, @args) = @_;

        getopt \@args, [qw(auto_abbrev)],
        'count=i' => \my $count,
          ;
        my @ids = @args; # remaining

        if (!scalar @ids) {
            my $jobs = $self->app->minion->backend->list_jobs(0, $count // 1,  # offset, limit
                                                              {state => 'inactive',
                                                               task => 'report',
                                                               queue => 'deferred',
                                                              }
                                                             );
            @ids = map { $_->{id} // () } @{$jobs->{jobs}}; # just the list of IDs
        }

        if (!scalar @ids) {
            $self->app->log->info("No jobs found to retry");
        }
        foreach my $id (@ids) {
            # ; $DB::single = 1;
            my $job = $self->app->minion->job($id);
            if (defined $job) {
                if ($job->retry({queue => 'default'})) {
                    $self->app->log->info("Released report job $id");
                } else {
                    $self->app->log->error("Failed to release job $id");
                }
            } else {
                $self->app->log->error("Failed to release job $id (ID not found)");
            }
        }

    }
}

1;
