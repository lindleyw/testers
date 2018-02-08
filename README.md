# testers
A rewrite of Ray's Perl Smoker Testers program

See https://github.com/raytestinger/testers

Purpose: To run tests on modules that are newly updated in CPAN
(or any other desired set of modules).

The results may be stored locally or transmitted to the CPAN testers,
from which they may be viewed.  Further information on accessing test
results:

http://blogs.perl.org/users/preaction/2017/07/cpan-testers-has-an-api.html

This system uses Mojo and Minion to divide the testing into steps,
each of which is performed and controlled by the Minion job queue.

BACKGROUND:

First, definitions. From the glossary of CPAN terminology, in brief we have:

  * A package is a namespace for Perl code, introduced with the
    package built-in.

  * A module is a file with a .pm extension that contains either a
    collection of functions, or a Perl class. Typically a module
    contains a package of the corresponding name.

  * A distribution is a collection of one or more modules and
    associated files that are released together.
  
  * A release is one instance of a distribution, with a given version
    number, that was released to PAUSE.

Source: http://neilb.org/2015/09/05/cpan-glossary.html

REQUIREMENTS:

    # For Debian/Ubuntu:
    $ sudo apt install sqlite3 libssl-dev zlib1g-dev

    $ cpanm Mojolicious Mojo::SQLite SQL::Abstract::More \
      Minion Minion::Backend::SQLite Email::Address \
      YAML App::cpanminus::reporter Yancy

CONFIGURATION:

The file smoketest.conf contains a number of configuration parameters,
along with explanatory comments.  The base keys are:

  * db: The SQLite database name

  * db_api: Submission URL and user agent for CPANTesters API
    submissions

  * cpan: Interface for retrieval from cpan.org, cpantesters.org,
    metacpan.org

  * smoker: Interface to `cpanm` command

USAGE:

    $ chmod a+x smoketest

To begin, build a database and download the list of packages from
CPAN:

    $ ./smoketest rebuild
    $ ./smoketest update

Optional arguments to update are:

    -v                    Verbose mode
    --count=10            How many releases to retrieve from MetaCPAN
    --distribution=Name   Specify a particular distribution to test
    --dist=Name           (abbreviation for --distribution)
    --version=0.9         Which version of the above distribution to test
    --release=Name-0.9    Combine distribution and version into
                          full release name
    --author=PREACTION    Specify an author
    --start_date=2017-01-01  Specify a starting date
    --end_date=2017-01-01 Specify an end date
    --perl_version=5.26.1 Specify one or more Perl versions
                          to test each release
    --force               Force testing even of releases
                          already tested or queued
    --notest              Do not enqueue any test jobs,
                          just add releases to database

Unless --distribution or --release is specified, only the latest
versions of a given distribution will be retrieved.

---

To display enqueued jobs:

    $ ./smoketest list

To display completed jobs:

    $ ./smoketest list finished

---

You can view the Minion AdminUI by starting a Mojolicious daemon:

    $ ./smoketest daemon &

The AdminUI is by default at http://localhost:3000.  You can specify
to listen at a different location as:

    $ ./smoketest daemon -l http://*:8080

---

Then start a worker process to actually perform the tests:

    $ ./smoketest minion worker &

You can monitor the progress by either examining the Minion job queue
directly:

     $ ./smoketest minion -s               # shows overall status
     $ ./smoketest minion job -S inactive  # shows queued jobs
     $ ./smoketest minion job -S finished  # shows completed jobs

or by pointing your browser at http://localhost:3000 (or the listen
address specified as above)

    /modules           module statistics
    /module/:modname   information about given module
    /tests/:modname    list of tests performed on a module
    /update            queue a job which will download the
                       module list from CPAN
    /update/*uri       download the module list from a location
    /apply             apply the Disabled list
    /job/:id           status of a given minion job
    del /job/:id       remove a minion job by id_number
    /jobs/stats        minion stats

Other Minion Worker command parameters are listed at:

    $ ./smoketest minion help worker

---

As tests complete, they will create a Minion job to submit the report
to the CPANTesters API.  By default these jobs are placed in Minion's
'deferred' queue and must be manually reviewed before being sent.  You
can list the reports awaiting approval with:

    $ ./smoketest list -r

which will emit a list like:

    Job   Status    Distribution                       Version  Perl  Grade
    1729  inactive  App-abgrep-0.003                   0.003          pass
    1728  inactive  CSS-DOM-0.17                       0.17           pass
    1727  inactive  Test-Time-HiRes-0.01               0.01           pass

And you can release jobs either as:

    $ ./smoketest release -count 3

which will release the 3 most recent tests, or by specifying job
numbers:

    $ ./smoketest release 1729 1727

---

Completed tests can be viewed at a URL as:

    http://localhost:3000/test/1729

This route responds to JSON with the full test structure, and to HTML
and TXT formats (TXT being the fallback default) with the combined log
output.  For example either of:

    $ ./smoketest get /test/1729?format=json
    $ ./smoketest get /test/1729.json

will display the test result structure in JSON format.  Possibly
useful will be the json_pp program:

    $ ./smoketest get /test/1729.json | json_pp

---

NOTE: Before a test is run, the name and version of the module are
tested against a YAML file which should contain (1) a regex that
selects one or more modules by name; and (2) the setting disabled=1.
Alternately, if it says disabled=0 then the regex will *enable* the
selected modules.  By default, only the 01.DISABLED.yml file from
the current CPAN version, in this format, is used.

---

NOTE: On running the cpanm-reporter command for first time, it asks a
bunch of options and then creates its configuration file:

  CPAN Testers: writing config file to '/home/YOUR_USER/.cpanreporter/config.ini'.

See CPAN::Testers::Common::Client::Config documentation for more
details.

