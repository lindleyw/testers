use strict;
use warnings;

package CPAN::Wrapper {

    use CPAN;           # Must be inside a module, not the main program, because we don't want to *run* cpan!
    use Capture::Tiny ':all';

    sub version {
        return $CPAN::VERSION;
    }

    # NOTE:  Possibly for later use, given further CPAN refactoring
    # 
    # sub run_test {
    #     # Use the CPAN Shell function to actually run a test.
    #     # Return the stdout and stderr logs.
    #     # NOTE: CPAN::Shell->test(...) calls its function rematein(...) which
    #     # does not return any useful value.
    #     my @args = @_;
    #     my ($stdout, $stderr, @result) = eval { capture { CPAN::Shell->test ( @args ) } };
    #     return ($stdout, $stderr);
    # }

};

1;
