from fabric.api import run, env, parallel, settings, local, hosts
from fabric.tasks import execute
from fabric.operations import put
from fabric.context_managers import cd, prefix


env.hosts = [  #TODO
	'f@localhost',
	'f@10.40.27.137',
	#'f@10.40.25.219',
	#'f@10.40.27.38',
	#'f@10.40.27.55',
]
env.linewise = True  #for parallel



@hosts('')
def pack ():
	local('tar --exclude="build" --exclude="*.log" --exclude="venv" --exclude="*.pyc" --exclude="bold_db" --exclude-vcs -czf src.tar.gz *')

@parallel
def upload ():
	put('src.tar.gz', '/tmp')
	try:
		run('tar -xf /tmp/src.tar.gz -C /home/f/proj/mistress-load')  #TODO
	finally:
		run('rm /tmp/src.tar.gz')

	with cd('/home/f/proj/mistress-load'):  #TODO
		with prefix('source venv/bin/activate'):  #TODO
			run('python build.py')

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
