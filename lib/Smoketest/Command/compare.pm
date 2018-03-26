package main::Command::compare {
    use Mojo::Base 'Mojolicious::Command';
    use Mojo::Util qw(getopt);

    has 'description' => 'Compares local distribution test results with those on cpantesters.org';

=pod

=head2 Compare

=cut

    has usage => <<"=cut" =~ s/  APPLICATION/$0/rg =~ s/\s+=pod\s+//rs;

=pod

    APPLICATION compare

    Operation of this remains to be determined.

=cut
    sub run {
        my ($self, @args) = @_;

        getopt \@args, [qw(auto_abbrev)],
          'v|verbose' => \my $verbose,   # Note abbrev, versus -version below
          'count=i' => \my $count,
          'distribution|distro=s' => \my @dists,
          'version=s' => \my @versions,  # one 'Release' is a 'Distribution-Version' combination
          'author=s' => \my @authors,
          'perl_version=s' => \my @perl_versions,
          'start_date=s' => \my $start_date,
          'end_date=s'   => \my $end_date;

        my $releases = $self->app->smoker->get_releases( { distribution => \@dists,
                                                           version => \@versions,
                                                           author => \@authors,
                                                         } );

        print "Found the following distributions:\n\n";
        print Mojo::Util::tablify [ [qw/id distribution version author/],
                                    map { [$_->@{qw(id distribution version author)}] } @{$releases} ];
        print "\n";

        # build a hash, key being the distribution name, value being an array of matching id's.
        my %release_ids;
        foreach my $rel (@{$releases}) {
            push @{$release_ids{$rel->{distribution}}}, $rel->{id};
        }

        foreach (sort keys %release_ids) {
            $self->app->smoker->compare_tests({distribution => $_, id => $release_ids{$_}});
        }
    }

};

1;
