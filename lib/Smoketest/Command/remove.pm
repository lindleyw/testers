package main::Command::remove {
    use Mojo::Base 'Mojolicious::Command';
    use Minion::Backend;
    use Mojo::Util qw(getopt);

    has 'description' => 'Remove a currently-enqueued test';

=pod

=head2 Remove

=cut

    has usage => <<"=cut" =~ s/  APPLICATION/$0/rg =~ s/\s+=pod\s+//rs;

=pod

Usage: APPLICATION remove [IDS] [-count N]

Removes one or more enqueued Minion jobs by ID, or from newest by count
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
                                                               task => 'test',
                                                               queue => 'default',
                                                              }
                                                             );
            @ids = map { $_->{id} // () } @{$jobs->{jobs}}; # just the list of IDs
        }

        if (!scalar @ids) {
            $self->app->log->info("No jobs found to remove");
        }
        foreach my $id (@ids) {
            my $job = $self->app->minion->job($id);
            if (defined $job) {
                if ($job->remove) {
                    $self->app->log->info("Removed job $id");
                } else {
                    $self->app->log->error("Failed to remove job $id");
                }
            } else {
                $self->app->log->error("Failed to remove job $id (ID not found)");
            }
        }

    }
}

1;
