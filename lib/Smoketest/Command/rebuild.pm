package Smoketest::Command::rebuild {

    use Mojo::Base 'Mojolicious::Command';

    has 'description' => 'Discard the entire testing database and rebuild its structure.';

=pod

=head2 Rebuild

=cut

    has usage => <<"=cut" =~ s/  APPLICATION/$0/rg =~ s/\s+=pod\s+//rs;

=pod

    APPLICATION rebuild

=cut

    sub run {
      my ($self) = @_;

      state $smoker = Tester::Smoker->new(database => $self->app->config->{dbname},
                                          config   => $self->app->config,
                                          log      => $self->app->log,
                                          rebuild  => 1,
                                         );
      $self->app->minion->reset;    # Also clear the Minion job queue
    }
};

1;
