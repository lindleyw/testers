package TestModule;

use v5.10;
use Data::Dumper;
use Mojo::File;
use File::Temp;
use Config;
use CPAN::Testers::Common::Client::Config;
use Time::HiRes qw(gettimeofday);

use strict;
use warnings;

my $verbose = 1;

use Capture::Tiny;

sub test_module {
    say "\nentering test_module\n" if ($verbose);
    system("date") if ($verbose);

    my ($params) = shift;
    say Dumper ($params) if ($verbose);

    # Find where our reports are going to be located
    my $cf = CPAN::Testers::Common::Client::Config->new;

    $cf->read;

    my $temp_dir_name = File::Temp->newdir;

    # by default this uses CLEANUP => 1 (c.f. File::Temp doc)

    my $module       = $params->{module};
    my $perl_release = $params->{perl_release};
    my $error        = '';

    # next two variable settings are explained in this link
    # http://www.dagolden.com/index.php/2098/the-annotated-lancaster-consensus
    local $ENV{NONINTERACTIVE_TESTING} = 1;
    local $ENV{AUTOMATED_TESTING}      = 1;

    local $ENV{PERL_CPANM_HOME} = $temp_dir_name;
    my ($secs, $msec) = gettimeofday();
    # my $temp_log = "/media/sg/logs/log.$secs.$msec";
    my $cpanm_test_command = "perlbrew exec";
    $perl_release //= $Config{version};   # use version currently executing
    $cpanm_test_command .= " --with $perl_release";
    $cpanm_test_command .= " cpanm --test-only $module"; # " > $temp_log 2>&1 ";
    # XXX: Maybe 2> error log?
    # TODO: Look for '!' in log files and report error

    say "cpanm_test_command $cpanm_test_command" if ($verbose);

    my $check_msg;
    $check_msg = check_exit( 'test', $cpanm_test_command )
      ;    # Error string if defined, undef = ok

    my $build_file = Mojo::File->new($temp_dir_name)->child('build.log');

# Regrettably, the system() command returns 1 both in the case of a module which
# cannot be found, and in the case of a module which was tested and failed.
# TODO: Can we resolve the difference between those cases?  Do we need to?
    $error .= $check_msg if defined $check_msg;

# ## XXX: Nice, but wrong. See above.
# if (defined $check_msg) {  # If an error occurred above,
#     return { success => 0,
#              error => $check_msg,
#              ( -e $build_file ) ? (build_log => $build_file->slurp) : () # Build log contents, if exists
#            };
# }

    # Both the build log and the report log, can go into the same directory
    # cpanm-reporter will put its report in the directory
    # indicated by the 'transport' setting in file config.ini
    # in the ~/.cpanmreporter directory
    # ~/.cpanmreporter
    local $ENV{CPANM_REPORTER_HOME} = $temp_dir_name;
    my $config_file = Mojo::File->new($temp_dir_name)->child('config.ini');

    local $ENV{PERL_CPAN_REPORTER_CONFIG} =
      $config_file->to_string;    # exact location of config.ini

# This only required for CPAN::Reporter, which we are not using here.
# local $ENV{PERL_CPAN_REPORTER_DIR} = $temp_dir_name; # directory for config.ini

    my $email = $cf->email_from;

    # Create a config.ini to override the default for cpanm-reporter
    $config_file->spurt(<<CONFIG);
edit_report=default:no
email_from=$email
send_report=default:yes
transport=File $temp_dir_name
CONFIG

    my $cpanm_reporter_command =
        "perlbrew exec --with $perl_release "
      . "cpanm-reporter --verbose "
      . "--build_dir=$temp_dir_name "
      . "--build_logfile=$build_file "
      . "--skip-history --ignore-versions --force ";

    if (
        defined(
            $check_msg = check_exit( 'reporter', $cpanm_reporter_command )
        )
      )
    {
        $error .= "$check_msg\n";
    }

# At long last, our hero returns and discovers:
# ${temp_dir_name}/{Status}.{module_name}-{build_env_stuff}.{timestamp}.{pid}.rpt
# ${temp_dir_name}/work/{timestamp}.{pid}/build.log

    my $test_results = Mojo::File->new($temp_dir_name)->list_tree;

# Find the report file.  Extract the result (e.g., 'fail') and return with the filename.
    my $report_file = $test_results->map(
        sub {
            /^${temp_dir_name}   # directory name at start
                                              \W+                 # path delimiter
                                              (\w+)\.             # grade
                                              .*\.                # module name and build_env stuff
                                              (\d+)\.(\d+)        # timestamp.pid
                                              \.rpt\z/x    # trailing extension
              ? ( $_, $1 ) : ();
        }
    );

    my ( $report_filename, $report_contents, $grade );
    if ( $report_file->size )
    {    # Report file exists.  Extract grade and contents.
        $report_filename = $report_file->[0]->to_string;
        $grade           = $report_file->[1];
        $report_contents = Mojo::File->new($report_filename)->slurp
          if ( -e $report_filename );
    }

# my $build_log = $test_results->grep(sub { /build.log$/ && !-l $_})->first; # ignore symlinks
    return {
        success => 1,    # Completed, although possibly with errors
        build_log => $build_file->slurp,   # Mojo::File->new($build_log)->slurp,
        report    => $report_contents,
        length($error) ? ( error => $error ) : (),
        grade => $grade,
    };
}

sub check_exit {

# Executes a system command.
# Returns a descriptive error if something went wrong, or undef if everything's OK
    my ( $what, $command ) = @_;

    my $signal_received;
    my $stderr;
    my $exit = eval {

        # setup to handle signals
        local $SIG{'HUP'}  = sub { $signal_received = "Hang up" };
        local $SIG{'INT'}  = sub { $signal_received = "Interrupt" };
        local $SIG{'STOP'} = sub { $signal_received = "Stopped" };
        local $SIG{'TERM'} = sub { $signal_received = "Term" };
        local $SIG{'KILL'} = sub { $signal_received = "Kill" };

        # this one won't work with apostrophes like above
        local $SIG{__DIE__} = sub { $signal_received = "Die" };

        $stderr = Capture::Tiny::capture_stderr(sub { system($command ); });
    };

    # undef from eval means Perl error
    # zero return from system means normal exit
    # -1 means failure to execute the command at all
    # other values as below

    # die "FIXME hey you , process the Stderr and look for lines with '!' in them?";

    print STDERR "*** $stderr ***\n" if defined $stderr;

    if ( !defined $exit ) {
        return "In command ($command), error: ($@)" . defined $signal_received
          ? " with signal: $signal_received"
          : '';
    }
    return undef if ( !$exit );

    if ( $exit == -1 ) {
        return "$what failed to execute: $!";
    }
    elsif ( $exit & 127 ) {
        return sprintf(
            "$what child died with signal %d, %s coredump",
            ( $exit & 127 ),
            ( $exit & 128 ) ? 'with' : 'without'
        );
    }
    return sprintf( "$what child exited with value %d", $exit >> 8 );
}

1;

