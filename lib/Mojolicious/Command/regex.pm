package main::Command::regex {
    use Mojo::Base 'Mojolicious::Command';

    has 'description' => 'Retrieves and updates, from metacpan, the cached copy of the regex for disabled modules';

=pod

=head2 Regex

=cut

    has usage => <<"=cut" =~ s/  APPLICATION/$0/rg =~ s/\s+=pod\s+//rs;

=pod

Usage: APPLICATION regex [yaml_file_path_or_URL]

Fetches and saves a YAML file containing a regular expression which
will either enable or disable modules. Usually only one of these is
used, namely the most recent 01.DISABLED.yml from CPAN. However, if
you wish to override some of that behaviour, you may add your own
regular expressions.  Your enable/disable regular expressions will be
processed after the default CPAN one.

The ability to manage and rearrange these regular expressions in the
smoker database is left as an exercise to the student.

=cut

    sub run {
        my ($self, @args) = @_;

        return $self->app->smoker->fetch_and_save_regex(@args);
    }

};

1;
