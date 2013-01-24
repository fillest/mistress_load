from fabric.api import run, env, parallel, settings, local, hosts
from fabric.tasks import execute
from fabric.operations import put
from fabric.context_managers import cd, prefix


env.linewise = True  #for parallel execution


@hosts('')
def pack ():
	local('tar --exclude="build" --exclude="*.log" --exclude="venv" --exclude="*.pyc" --exclude="*.a" --exclude="*.o" --exclude="bold_db" --exclude-vcs -czf src.tar.gz *')

@parallel
def upload ():
	path = '~/proj/mistress-load'  #TODO hardcode

	put('src.tar.gz', '/tmp')
	try:
		run('rm -rf {path}/src && mkdir -p {path} && tar -xf /tmp/src.tar.gz -C {path}'.format(path = path))  
	finally:
		run('rm /tmp/src.tar.gz')

	with cd(path):
		run('test -f venv/bin/activate'
			' || (virtualenv --no-site-packages venv'
			' && source venv/bin/activate'
			' && pip install --upgrade pip'
			' && pip install git+https://github.com/fillest/bold.git'
			' && pip install argparse)')
		with prefix('source venv/bin/activate'):  #TODO (?)
			run('bold')

@hosts('')
def clean ():
	local('rm -f src.tar.gz')

@hosts('')
def deploy ():
	try:
		execute(pack)
		execute(upload)
	finally:
		execute(clean)
