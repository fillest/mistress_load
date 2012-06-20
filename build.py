import sys
import glob
import subprocess
import os.path
import os
import bold


class Builder (bold.Builder):
	def add_options (self, parser):
		#~ parser.add_argument('--dev', action='store_true', help="dev build")
		parser.add_argument('--forcesl', action='store_true', help="force make luajit .so symlinks")
		parser.add_argument('--build-dir', '-b', dest='build_dir')

builder = Builder()



#build_dir = builder.opts.build_dir or 'build/dev'
build_dir = 'build/dev'


@builder.task
class ConfigBuilder (object):
	def build (self, build_dir, clean, dry, log, deps, _targets):
		log.info("build config.h")

		out_fp = build_dir + '/config.h'
		in_fp = 'src/config.h.in'
		if not dry:
			with open(in_fp, 'r') as tpl:
				with open(out_fp, 'w') as out:
					out.write(tpl.read() % dict(lua_src_path=os.path.abspath('src'), lua_use_luajit=1))

		clean.append(out_fp)

		deps.add(in_fp, out_fp, self)
		deps.add(out_fp, None, self)


_prefix = os.path.abspath(build_dir + '/luajit')

@builder.task
class LuajitBuilder (object):
	def build (self, _build_dir, clean, dry, log, deps, _targets):
		log.info("build luajit")

		with bold.change_cwd('src/luajit'):
			cmd = "make amalg CCDEBUG=' -g' BUILDMODE=' dynamic' PREFIX={prefix} && make install PREFIX={prefix}".format(prefix = _prefix)
			log.info("running: " + cmd)
			fail = subprocess.call(cmd, shell=True)

			subprocess.call(['make', 'clean'])

			if fail:
				sys.exit(1)

			if builder.opts.forcesl:
				subprocess.call("ln -s /home/f/proj/mistress-load/build/dev/luajit/lib/libluajit-5.1.so.2.0.0 /home/f/proj/mistress-load/build/dev/luajit/lib/libluajit-5.1.so", shell=True)
				subprocess.call("ln -s /home/f/proj/mistress-load/build/dev/luajit/lib/libluajit-5.1.so.2.0.0 /home/f/proj/mistress-load/build/dev/luajit/lib/libluajit-5.1.so.2", shell=True)
			out_fpath = _prefix + '/lib/libluajit-5.1.so'
			assert os.path.isfile(out_fpath) #can fail silently if failed to make symlink

#		clean.append(out_fpath)

		for fpath in bold.recursive_list_files('src/luajit/', ['src/luajit/doc/*']):
			deps.add(fpath, out_fpath, self)
		deps.add(out_fpath, None, self)
		#its .so so we don't rebuild exe on change


@builder.task
class Mistress (bold.ProgramBuilder):
	require = [ConfigBuilder, LuajitBuilder]

	target = build_dir + '/mistress'

	_dynsym_fpath = 'dynsym.txt'
	source = glob.glob('src/*.c') + [_dynsym_fpath]
	includes = [
		'src/luajit/src',
		build_dir,
	]
	flags = '-O3 -g -std=gnu99'
	exe_flags = '-Wl,--dynamic-list=%s -Wl,-rpath=%s/luajit/lib/' % (_dynsym_fpath, build_dir) #TODO rpath must be absolute?
	libpaths = [
		'%s/luajit/lib' % build_dir,
	]
	libs = [
		'm',
		'z',
		'luajit-5.1',
		#~ 'pthread',
	]


builder.run(build_dir)
