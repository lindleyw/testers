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

    $ cpanm Mojolicious Mojo::SQLite Minion Minion::Backend::SQLite\
      YAML App::cpanminus::reporter SQL::Abstract::More Yancy

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

The AdminUI is by default at http://localhost:3000

---

Then start a worker process to actually perform the tests:

    $ ./smoketest minion worker &

You can monitor the progress by either examining the Minion job queue
directly:

     $ ./smoketest minion -s               # shows overall status
     $ ./smoketest minion job -S inactive  # shows queued jobs
     $ ./smoketest minion job -S finished  # shows completed jobs

or by pointing your browser at http://localhost:3000

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

---
(obsolete section) -- (CHANGE to explain building your own exclude file)
NOTE: The above step uses a YAML file which should contain (1) a regex
that selects one or more modules by name; and (2) the setting
disabled=1.  Alternately, if it says disabled=0 then the regex will
*enable* the selected modules.
---

TODO: Also allow loading local files and setting priority, as:

    $ ./smoketest disable ~/mydisabled.yml --priority 10

TODO: Pick a better verb instead of the possibly misleading 'disable'

---



==========

running cpanm-reporter for first time:

  See CPAN::Testers::Common::Client::Config documentation for more
  details.

asks a bunch of options and then:

  CPAN Testers: writing config file to '/home/billl/.cpanreporter/config.ini'.


==========

releases within last 2 days --? izzit true?

curl -XPOST 'https://fastapi.metacpan.org/v1/file' -d "$(curl -Ls gist.github.com/metacpan-user/5705999/raw/body.json)"

with:

---begin---
{
  "query": {
    "match_all": {}
  },
  "filter": {
    "and": [
      {
        "term": {
          "path": "cpanfile"
        }
      },
      {
        "term": {
          "status": "latest"
        }
      },
      {
        "range" : {
            "date" : {
                "gte" : "now-2d/d",
                "lt" :  "now/d"
            }
        }        
      }    
    ]
  },
  "fields": [
    "release", "date"
  ],
  "size": 200
}
---end---

or:

---begin---
{ "query": { "match_all": {} }, "filter": { "and": [ { "term": { "path": "cpanfile" } }, { "term": { "status": "latest" } }, { "or": [ {"term" : { "author" : "PREACTION" } }, {"term" : { "author" : "JBERGER" }} ] } ] }, "fields": [ "release", "date", "author" ], "size": 200 }
---end---

                                                                                 
{ 'size' => 200,
  'fields' => ['release', 'date', 'author', 'download_url', 'version'],
  'filter' => {'and' => [ {'term' => {'path' => 'cpanfile'}},
                          {'term' => {'status' => 'latest'}},
                          {'or' => [{'term' => {'author' => 'PREACTION'}},
                                      {'term' => {'author' => 'JBERGER'}}]}
                         ]},
  'query' => {'match_all' => {}}
}

