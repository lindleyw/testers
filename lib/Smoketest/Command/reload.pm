package main::Command::reload {
    use Mojo::Base 'Mojolicious::Command';

    has 'description' => 'Reloads the entire list of modules from MetaCPAN';

=pod

=head2 Reload

=cut

    has usage => <<"=cut" =~ s/  APPLICATION/$0/rg =~ s/\s+=pod\s+//rs;

=pod

Usage: APPLICATION reload [options]

Reloads the entire list of current packages from CPAN, usually from
its 02packages.details.txt file.

=cut

    sub run {
        my ($self, @args) = @_;
        my $updated_releases = $self->app->smoker->get_all(@args);
        if ($self->app->smoker->check_regex(release_id => $updated_releases)) {
            $self->app->log->info("modules updated OK");
        } else {
            $self->app->log->error("could not update module list");
        }
    }
};

1;
