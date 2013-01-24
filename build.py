import bold
from bold import build_path
import os
import sys
import shutil


class Luajit (bold.builders.Builder):
	required_by = lambda: Mistress.target
	
	src_path = 'src/luajit'
	src_copy_path = build_path + 'luajit_src'
	target = src_copy_path + '/src/libluajit.a'
	sources = lambda self: list(bold.util.get_file_paths_recursive(self.src_path, [self.src_path + '/doc/*']))

	def build (self, _changed_targets, _src_paths):
		shutil.rmtree(self.resolve(self.src_copy_path), ignore_errors = True)
		shutil.copytree(self.src_path, self.resolve(self.src_copy_path))

		with bold.util.change_cwd(self.resolve(self.src_copy_path)):
			self.shell_run('''make amalg CCDEBUG=" -g" BUILDMODE=" static"''')
		self._update_target(self.target)

class Mistress (bold.builders.CProgram):
	target = build_path + 'mistress'
	# _dynsym_fpath = 'dynsym.txt'
	# sources = 'src/*.c', _dynsym_fpath
	sources = 'src/*.c'
	compile_flags = """-O3 -g -std=gnu99 -DLUA_USE_LUAJIT=1 -DLUA_SRC_PATH='"%s"' """ % os.path.abspath('src')  #-Wall
	includes = [
		Luajit.src_path + '/src',
	]
	# exe_flags = '-Wl,--dynamic-list=%s -Wl,-rpath=%s/luajit/lib/' % (_dynsym_fpath, build_dir) #TODO rpath must be absolute?
	# link_flags = '-Wl,--dynamic-list=%s' % (_dynsym_fpath,)
	link_flags = '-Wl,--export-dynamic'
	lib_paths = [
		Luajit.src_copy_path + '/src',
		# '%s/luajit/lib' % build_dir,
	]
	libs = [
		# 'pthread',
		# 'luajit-5.1',
		'luajit',
		'dl',
		'm',
		'z',
	]
