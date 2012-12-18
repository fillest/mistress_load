# Mistress - load testing tool for server-side applications

## Feature highlights
* Scenario scripting in [Lua](http://en.wikipedia.org/wiki/Lua_%28programming_language%29)
* Live-updated statistic plots viewable through web interaface
* Persistent test history with project grouping and ACL
* HTTP support - keep-alive, chunked, gzip, automatic cookie management, basic-auth, file upload
* Parallel requests from one virtual user (e.g. like browsers act)
* Special proxy for recording HTTP requests and generating test scripts
* Scales with cores and nodes
* Extension system
* *(planned)* Monitoring integration

## Goals
* Easy and powerful scenario scripting
* Accurate informative statistics
* High performance

## Current status
Under active development but is already working. Stay tuned for docs appearance.

## Near-future roadmap
1. Some high-priority features/improvements
1. Docs
1. Refactoring (i was coding in a real hurry)
1. Tests

## Supported platforms
Currently I test on Debian and Ubuntu. Mistress should work on other popular Linux distributions, FreeBSD and Mac OS as well, please drop me any feedback (especially if something doesn't work smoothly, or non-platform-optimal event notification mechanism gets used).

## Setup
### Prepare
    #ubuntu 12.10:
    sudo apt-get install lua-socket lua-json lua-logging
    #older debian-based?:
    sudo apt-get install liblua5.1-socket2 liblua5.1-json liblua5.1-logging
    
    sudo apt-get install zlib1g-dev
    sudo apt-get install screen

    sudo apt-get install git
    git clone https://github.com/fillest/mistress-load.git
    cd mistress-load

    sudo apt-get install python-virtualenv
    virtualenv --no-site-packages venv
    source venv/bin/activate
    pip install --upgrade pip  #debian?
    pip install git+https://github.com/fillest/bold.git
    pip install argparse #for debian
    
    bold

## Usage
First, start statistics server (or use `no_stat_server = true` in script).

...Set up ssh keys

`build/dev/mistress -s <your-test-script-name>`

Chech report at http://localhost:7777/report/list

##*Any feedback or help (especially with tests, docs and spreading the word) is highly appreciated! My email: fsfeel@gmail.com*

## A few words about internals
Written in [C(C99)](http://en.wikipedia.org/wiki/C99) and [Lua](http://en.wikipedia.org/wiki/Lua_%28programming_language%29)/[LuaJIT](http://luajit.org/) using [libev](http://software.schmorp.de/pkg/libev.html) and [HTTP Parser](https://github.com/joyent/http-parser) libs

Non-blocking io + libev + lua coroutines; coroutines yield on issuing io and resume on result, so end-user code is simple and natural (threading-style), without ugly callback boilerplate.

Metrics are accumulated and periodically sent to stand-alone statictics server.

##License
[The MIT License](http://www.opensource.org/licenses/mit-license.php)
