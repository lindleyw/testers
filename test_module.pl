sub test_module {

# arg contains (example)
# http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/Acme-Devel-Hide-Tiny-0.001.tar.gz
    my ($module) = @_;
    say "arg to test_module input:  $module " if ($verbose);

    # get list of perl builds to test modules against,
    # this list could change while script is running,
    # so read it here
    # make sure there's some time between output file timestamps
    for $perlbuild (@revs) {
        chomp $perlbuild;
        sleep 2;

        say "starting test process for perl build $perlbuild" if ($verbose);
        system("date");

        eval {
            # setup to handle signals
            local $SIG{'HUP'}  = sub { say "Got hang up" };
            local $SIG{'INT'}  = sub { say "Got interrupt" };
            local $SIG{'STOP'} = sub { say "Stopped" };
            local $SIG{'TERM'} = sub { say "Got term" };
            local $SIG{'KILL'} = sub { say "Got kill" };

            # this one won't work with apostrophes like above
            local $SIG{__DIE__} = sub { say "Got die" };

            # next two variable settings are explained in this link
### http://www.dagolden.com/index.php/2098/the-annotated-lancaster-consensus
            local $ENV{NONINTERACTIVE_TESTING} = 1;
            local $ENV{AUTOMATED_TESTING}      = 1;

            # cpanm will put its test reports in this directory,
            # cpanm-reporter will get its input from this directory
            local $ENV{PERL_CPANM_HOME} = "$function_cpanm_home/$perlbuild";
            say "PERL_CPANM_HOME is:  $ENV{PERL_CPANM_HOME}" if ($verbose);

            my $BUILD_DIR     = $ENV{PERL_CPANM_HOME};
            my $BUILD_LOGFILE = "$BUILD_DIR/build.log";

            unless ( -d $BUILD_DIR ) {
                mkdir $BUILD_DIR;
                system("chmod 777 $BUILD_DIR");
            }

            say "BUILD_DIR is: $BUILD_DIR for $perlbuild"         if ($verbose);
            say "BUILD_LOGFILE is: $BUILD_LOGFILE for $perlbuild" if ($verbose);

            # isolate module name
            $module = substr( $module, 0, rindex( $module, '-' ) )
              if ( $module =~ /-/ );
            say "module name cleared of final dash:  $module" if ($verbose);

            $module = substr( $module, rindex( $module, '/' ) + 1 );
            $module =~ s/-/::/g;

            # test the module, don't install it
            my $command = "perlbrew exec --with $perlbuild ";
            $command .= "cpanm --test-only $module ";
            $command .= "| tee $test_log_home/$module.$perlbuild ";
            say "about to test $module for $perlbuild" if ($verbose);
            system("which perl") if ($verbose);
            check_test_exit( system("$command") );
            say "Should have completed testing $module for $perlbuild"
              if ($verbose);

            # The system() command above creates a directory like
            # ~/.cpanm/work/TIMESTAMP.PID e.g., 1499707240.6465
            # containing:
            #    build.log
            #    Mojolicious-7.36   # directory name is module and version
            #    " " " .tar.gz

            # if ls output missing, testlog not created
            # if Succ tested not found, test failed
            # if Succ tested found, test passed
            # rewrite this to avoid shelling out

            system("echo >> tlog");
            system("ls $test_log_home/$module.$perlbuild >> tlog 2>&1");
            system(
"grep \'Successfully tested\' $test_log_home/$module.$perlbuild >> tlog 2>&1"
            );

            # have test reports sent by a separate task
        };
    }
}

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
