package TestModule;

use v5.10;
use Data::Dumper;

sub test_module {
    my $verbose = 1;
    say "\nentering test_module\n" if ($verbose);

    my ($params) = shift;
    say Dumper ($params) if ($verbose);

    my $module       = $params->{module};
    my $perl_release = $params->{perl_release};
 
    # next two variable settings are explained in this link
	# http://www.dagolden.com/index.php/2098/the-annotated-lancaster-consensus
    $NONINTERACTIVE_TESTING = 1;
    $AUTOMATED_TESTING      = 1;

    system("date");

    # isolate module name
    $module = substr( $module, 0, rindex( $module, '-' ) )
      if ( $module =~ /-/ );
    $module = substr( $module, rindex( $module, '/' ) + 1 );
    $module =~ s/-/::/g;

    # test the module, don't install it
    my $command = "perlbrew exec --with $perl_release ";
    $command .= "cpanm --test-only $module ";
    say "about to test $module for $perl_release" if ($verbose);

    # cpanm will put its test report in the default directory:
    #  ~/cpanm/build.log 
    check_test_exit( system("$command") );
    say "Should have completed testing $module for $perl_release"
      if ($verbose);

    say "CPANM_REPORTER_HOME is $CPANM_REPORTER_HOME"
      if ($verbose);

    $PERL_CPAN_REPORTER_DIR = "~/.cpanmreporter";
    $command = "perlbrew exec --with $perl_release ";
    $command .= "cpanm-reporter --verbose ";
    $command .= "--skip-history --ignore-versions --force ";

    say "About to send cpanm report for $perl_release: \n  $command"
      if ($verbose);
    check_reporter_exit( system($command) );
    say
"Should have completed sending cpanm report for $perl_release :\n  $command"
      if ($verbose);

}
warn("bad exit from test_module subr") if $@;

sub check_test_exit {
    my ($exit) = @_;
    if ( $exit == -1 ) {
        say "test failed to execute: $!";
    }
    elsif ( $exit & 127 ) {
        printf "test child died with signal %d, %s coredump\n",
          ( $exit & 127 ), ( $exit & 128 ) ? 'with' : 'without';
    }
    else {
        printf "test child exited with value %d\n", $exit >> 8;
    }
}

sub check_reporter_exit {
    my ($exit) = @_;
    if ( $exit == -1 ) {
        say "reporter failed to execute: $!";
    }
    elsif ( $exit & 127 ) {
        printf "reporter child died with signal %d, %s coredump\n",
          ( $exit & 127 ), ( $exit & 128 ) ? 'with' : 'without';
    }
    else {
        printf "reporter child exited with value %d\n", $exit >> 8;
    }
}
#close STDOUT;
#close STDERR;
1;

