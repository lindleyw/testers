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

has 'cpan_config' => sub {
    my $cf = CPAN::Testers::Common::Client::Config->new;
    $cf->read;
    return $cf;
};
has 'log';

has 'perlbrew' => 'perlbrew exec --with';

has 'cpanm_test' => 'cpanm --test-only';
has 'local_lib';    # If set, use '-L' and this to keep test
                    # dependencies separate from the ordinary
                    # installation
has 'timeout' => 300; # in seconds

sub verify {
    # Do we have a suitable environment for testing?  For now, require
    # only that the user has configured an email address for CPAN
    # reports.
    my ($self) = @_;
    return defined $self->cpan_config->email_from;
}

my $verbose = 0;

use Capture::Tiny;

sub with_perl {
    my ($self, $command, $perl_release) = @_;
    return (defined $perl_release) ? join(' ',$self->perlbrew, $perl_release, $command) : $command;
}

sub run {
    my ($self, $params) = @_;

    # Load default system config (see above) now, before $ENV{}
    # settings are in effect
    my $email = $self->cpan_config->email_from;

    # Create temporary directory, automatically purged by default this
    # uses CLEANUP => 1 (c.f. File::Temp doc)
    my $temp_dir_name = File::Temp->newdir;

    my $module       = $params->{module};
    my $perl_release = $params->{perl_release};
    my $error        = '';
    my ( $report_filename, $report_contents, $grade );
    my $reporter_exit;

    # next two variable settings are explained in this link
    # http://www.dagolden.com/index.php/2098/the-annotated-lancaster-consensus
    local $ENV{NONINTERACTIVE_TESTING} = 1;
    local $ENV{AUTOMATED_TESTING}      = 1;

    local $ENV{PERL_CPANM_HOME} = $temp_dir_name;

    # Build test command
    my @cpanm_args = ($self->cpanm_test);
    if ($self->local_lib) {  # This is the root of the local_libs
        my $use_lib = Mojo::File->new($self->local_lib);
        # Version-specific local_lib; also keep separate local_lib for default Perl.
        push @cpanm_args, '-L', $use_lib->child($perl_release // 'default');
    }
    push @cpanm_args, $module;

    my $cpanm_test_command = $self->with_perl(join(' ', @cpanm_args), $perl_release);

    # Execute command; track elapsed time; save status and output.
    $self->log->info("Shelling to: $cpanm_test_command") if (defined $self->log);
    my @start_time = gettimeofday();
    my $test_exit = $self->check_exit( $cpanm_test_command );     # Child process's exit value;
                                # negative means our exception (cannot execute; timeout)
    my $elapsed_time = tv_interval(\@start_time, [gettimeofday]); # Elapsed time as floating seconds

    my $build_file = Mojo::File->new($temp_dir_name)->child('build.log');

    # Both logs (build and report) can go into the same directory.
    # cpanm-reporter will put its report in the directory indicated by
    # the 'transport' setting in config.ini, which we override below
    local $ENV{CPANM_REPORTER_HOME} = $temp_dir_name;

    if ($test_exit->{finished}) {
        # Create a config.ini with our settings, to be used by both
        # cpanreporter and cpanm-reporter; set env to force its use
        my $config_file = Mojo::File->new($temp_dir_name)->child('config.ini');
        $config_file->spurt(<<CONFIG);
edit_report=default:no
email_from=$email
send_report=default:yes
transport=File $temp_dir_name
CONFIG
        local $ENV{PERL_CPAN_REPORTER_CONFIG} = $config_file->to_string;

        # Below required only for CPAN::Reporter, which we are not using here:
        # local $ENV{PERL_CPAN_REPORTER_DIR} = $temp_dir_name; # directory for config.ini

        # Build and execute the reporter command
        my $cpanm_reporter_command =
        "cpanm-reporter --verbose "
        . "--build_dir=$temp_dir_name "
        . "--build_logfile=$build_file "
        . "--skip-history --ignore-versions --force ";

        $reporter_exit = $self->check_exit(
             $self->with_perl($cpanm_reporter_command, $perl_release) );

        # At long last, our hero returns and can discover these files:
        # ${temp_dir_name}/{Status}.{module_name}-{build_env_stuff}.{timestamp}.{pid}.rpt
        # ${temp_dir_name}/work/{timestamp}.{pid}/build.log
        my $test_results = Mojo::File->new($temp_dir_name)->list_tree;

        # Find the report file.  Extract the complete filename and the result (e.g., 'fail').
        my $report_file = $test_results->map(
                                             sub {
                                                 /^${temp_dir_name}   # directory name at start
                                                  \W+                 # path delimiter
                                                  (\w+)\.             # grade
                                                  .*\.                # module name and build_env stuff
                                                  (\d+)\.(\d+)        # timestamp.pid
                                                  \.rpt\z/x # trailing extension
                                                  ? ( $_, $1 ) : (); # filename and grade
                                             }
                                            );

        if ( $report_file->size ) {           # Report file exists.  Extract grade and contents.
            $report_filename = $report_file->[0]->to_string;
            $grade           = $report_file->[1];
            if ( -e $report_filename ) {
                $report_contents = Mojo::File->new($report_filename)->slurp;
            }
        }
    }

    return {
            success => 1,                      # Completed, although possibly with errors
            build_log => $build_file->slurp,   # …from above
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
    my ( $self, $command ) = @_;

    my $signal_received;
    my $error_output;      # STDERR only
    my $merged_output;     # STDOUT, STDERR merged
    my $exit = eval {

        # setup to handle signals
        local $SIG{'HUP'}  = sub { $signal_received = "Hang up" };
        local $SIG{'INT'}  = sub { $signal_received = "Interrupt" };
        local $SIG{'STOP'} = sub { $signal_received = "Stopped" };
        local $SIG{'TERM'} = sub { $signal_received = "Term" };
        local $SIG{'KILL'} = sub { $signal_received = "Kill" };

        # this one won't work with apostrophes like above
        local $SIG{__DIE__} = sub { $signal_received = "Die" };

        # TODO: We would really like to create these variables:
        #   $merged_output    STDOUT+STDERR merged (buffered, mixed) as CPAN Testers expects
        #   $stderr_only      Just STDERR, useful for quickly finding what went wrong
        #   $exit_value       from the child process

        my $ALARM_EXCEPTION = "Child Process timed out";
        my $exit_value;
        eval {
            local $SIG{ALRM} = sub { die $ALARM_EXCEPTION };
            alarm $self->timeout if defined $self->timeout;
            ($merged_output, my $e_v) =
            Capture::Tiny::capture_merged( sub {
                                               ($error_output, $exit_value) =
                                               Capture::Tiny::tee_stderr( sub { system( $command ); });
                                           }
                                         );
            alarm 0;
        };
        alarm 0; # race condition protection
        if ($@ && $@ =~ quotemeta($ALARM_EXCEPTION)) { $exit_value = -2 }

        return $exit_value;   # NOTE: return from eval{} not from subroutine
    };

    # $exit set from the eval{} above;
    # undef = Perl error;
    #  0 = return from system with normal exit;
    # -1 = failure to execute the command at all;
    # -2 = timeout
    # other values as below

    # Regrettably, the system() command returns 1 both in the case of a module which
    # cannot be found, and in the case of a module which was tested and failed.
    # The below should help decipher these cases.

    my $status = { command => $command,
                 };
    $status->{stderr} = $error_output if defined $error_output;
    $status->{merged_output} = $merged_output if defined $merged_output;
    $status->{signal_received} = $signal_received if defined $signal_received;
    if (! $exit) {
        $status->{finished} = 1;   # Child process completed
        return $status;
    }

    if ( $exit == -1 ) {
        $status->{exec_fail} = 1;
        $status->{error} = "Failed to execute: $!";
    } elsif ( $exit == -2 ) {
        $status->{timeout} = 1;
        $status->{error} = "Process timed out";
    } else {
        if ($exit & 127) {
            $status->{signal} = ($exit & 127);
            $status->{coredump} = !!($exit & 128);
            $status->{error} = sprintf(
                                       "Child died with signal %d, %s coredump",
                                       ( $status->{signal} ),
                                       ( $status->{coredump} ) ? 'with' : 'without'
                                      );
        } else {
            $status->{finished} = 1;   # Child process completed, possibly with exit value
            $status->{exit_value} = $exit >> 8;
            $status->{error} = sprintf( "Child exited with value %d", $status->{exit_value} );
        }
    }

    $self->log->warn($status->{command} . ' --> ' . $status->{error}) if defined $self->log;
    return $status;
}

1;

