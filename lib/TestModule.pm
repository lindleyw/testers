package TestModule;

use v5.10;
use Mojo::Base '-base';
use Mojo::File;
use File::Temp;
use Config;
use CPAN::Testers::Common::Client::Config;
use Time::HiRes qw(gettimeofday tv_interval);

use strict;
use warnings;

has 'config' => sub {
    my $cf = CPAN::Testers::Common::Client::Config->new;
    $cf->read;
    return $cf;
};

my $verbose = 0;

use Capture::Tiny;

sub run {
    say "\nentering test_module\n" if ($verbose);
    system("date") if ($verbose);

    my ($self, $params) = @_;
    # use Data::Dumper;
    # say Dumper ($params) if ($verbose);

    # Find where our reports are going to be located

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
    my @start_time = gettimeofday();

    # Build test command
    my $cpanm_test_command = "cpanm --test-only $module";
    if (defined $perl_release) {   # prepend to use Perlbrew
        $cpanm_test_command = "perlbrew exec --with $perl_release " . $cpanm_test_command;
    }

    say "  Shelling to: $cpanm_test_command" if ($verbose);
    # Execute command; save status and output
    my $test_exit = check_exit( $cpanm_test_command );
    my $elapsed_time = tv_interval(\@start_time, [gettimeofday]); # Elapsed time as floating seconds

    my $build_file = Mojo::File->new($temp_dir_name)->child('build.log');

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

    my $email = $self->config->email_from;

    # Create a config.ini to override the default for cpanm-reporter
    $config_file->spurt(<<CONFIG);
edit_report=default:no
email_from=$email
send_report=default:yes
transport=File $temp_dir_name
CONFIG

    my $cpanm_reporter_command =
      "cpanm-reporter --verbose "
      . "--build_dir=$temp_dir_name "
      . "--build_logfile=$build_file "
      . "--skip-history --ignore-versions --force ";
    if (defined $perl_release) {  # prepend for Perlbrew
        $cpanm_reporter_command = "perlbrew exec --with $perl_release " . $cpanm_reporter_command;
    }

    my $reporter_exit = check_exit( $cpanm_reporter_command );

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
            test_exit => $test_exit,
            reporter_exit => $reporter_exit,
            start_time => $start_time[0],
            elapsed_time => $elapsed_time,
    };
}

sub check_exit {

# Executes a system command.
# Returns a descriptive error if something went wrong, or undef if everything's OK
    my ( $command ) = @_;

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

        my $exit_value;
        $stderr = Capture::Tiny::capture_stderr(sub { $exit_value = system($command ); });
        return $exit_value;
    };

    # undef from eval means Perl error
    # zero return from system means normal exit
    # -1 means failure to execute the command at all
    # other values as below

    # Regrettably, the system() command returns 1 both in the case of a module which
    # cannot be found, and in the case of a module which was tested and failed.
    # The below should help decipher these cases.

    my $status = {};
    $status->{stderr} = $stderr if defined $stderr;
    $status->{command} = $command;
    $status->{signal_received} = $signal_received if defined $signal_received;
    return $status if ( !$exit );

    if ( $exit == -1 ) {
        $status->{error} = "Failed to execute: $!";
    } elsif ( $exit & 127 ) {
        $status->{error} = sprintf(
                                   "Child died with signal %d, %s coredump",
                                   ( $exit & 127 ),
                                   ( $exit & 128 ) ? 'with' : 'without'
                                  );
    } else {
        $status->{error} = sprintf( "Child exited with value %d", $exit >> 8 );
    }
    return $status;
}

1;

