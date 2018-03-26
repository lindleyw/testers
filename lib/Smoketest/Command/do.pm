package Smoketest::Command::do {
    use Mojo::Base 'Mojolicious::Command';

    has 'description' => 'Run any enqueued tests immediately, without using Minion workers';

=pod

=head2 Do

=cut

    has usage => <<"=cut" =~ s/  APPLICATION/$0/rg =~ s/\s+=pod\s+//rs;

=pod

Force immediate in-this-thread execution of all Minion jobs
sequentially

Compare to:

    APPLICATION minion worker

which starts a Minion worker daemon to process jobs, potentially
running multiple jobs simultaneously.

=cut

    sub run {
        my ($self) = @_;
        if (!$self->app->smoker->tester->verify) {
            die "Cannot run tests. (Have you configured an email address for cpanm-reporter?)"
        }
        $self->app->minion->perform_jobs();
    }
};

1;
