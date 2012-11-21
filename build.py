import bold
from bold import build_path
import os
import sys


# platform_name, _, _ = platform.dist()
# is_debian = platform_name.lower() == 'debian'


class Luajit (bold.builders.Builder):
	src_path = 'src/luajit'
	target = src_path + '/src/libluajit.a'
	required_by = lambda: Mistress.target
	sources = lambda self: list(bold.util.get_file_paths_recursive(self.src_path, [self.src_path + '/doc/*']))

	def build (self, _changed_targets, _src_paths):
		with bold.util.change_cwd(self.src_path):
			self.shell_run('''make amalg CCDEBUG=" -g" BUILDMODE=" static"''')
		self._update_target(self.target)

# 		with bold.change_cwd('src/luajit'):
# 			cmd = "make amalg CCDEBUG=' -g' BUILDMODE=' dynamic' PREFIX={prefix} && make install PREFIX={prefix}".format(prefix = _prefix)
# 			log.info("running: " + cmd)
# 			fail = subprocess.call(cmd, shell=True)

# 			subprocess.call(['make', 'clean'])

# 			if fail:
# 				sys.exit(1)

# 			if is_debian or builder.opts.forcesl:
# 				libpath = _prefix + '/lib/libluajit-5.1.so.2.0.0'
# 				subprocess.check_call("ln -s %s %s/lib/libluajit-5.1.so" % (libpath, _prefix), shell=True)
# 				subprocess.check_call("ln -s %s %s/lib/libluajit-5.1.so.2" % (libpath, _prefix), shell=True)
# 			out_fpath = _prefix + '/lib/libluajit-5.1.so'
# 			assert os.path.isfile(out_fpath) #can fail silently if failed to make symlink

class Config (bold.builders.Builder):
	target = build_path + 'config.h'
	required_by = lambda: Mistress.target
	sources = 'src/config.h.in'

	def build (self, _changed_targets, _src_paths):
		with open(self.sources, 'r') as tpl:
			with open(self.resolve(self.target), 'w') as out:
				out.write(tpl.read() % dict(lua_src_path=os.path.abspath('src'), lua_use_luajit=1))
		self._update_target(self.target)

class Mistress (bold.builders.CProgram):
	target = build_path + 'mistress'
	# _dynsym_fpath = 'dynsym.txt'
	# sources = 'src/*.c', _dynsym_fpath
	sources = 'src/*.c'
	compile_flags = '-O3 -g -std=gnu99' #-Wall
	includes = [
		Luajit.src_path + '/src',
		build_path,
	]
	# exe_flags = '-Wl,--dynamic-list=%s -Wl,-rpath=%s/luajit/lib/' % (_dynsym_fpath, build_dir) #TODO rpath must be absolute?
	# link_flags = '-Wl,--dynamic-list=%s' % (_dynsym_fpath,)
	link_flags = '-Wl,--export-dynamic'
	lib_paths = [
		Luajit.src_path + '/src',
		# '%s/luajit/lib' % build_dir,
	]
	libs = [
		'luajit',
		'dl', #wtf?
		'm',
		'z',
		# 'luajit-5.1',
		# 'pthread',
	]
