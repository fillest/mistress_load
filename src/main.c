#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
//#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <stddef.h>
#include <netinet/tcp.h>
#include <assert.h>
#include <stdbool.h>
#include <time.h>

#include <zlib.h>
//~ #include <ev.h>
#include "libev.h"
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include "http_parser.h"


typedef struct composite_io_watcher {
	int coroutine_id;
	ev_tstamp started;
    ev_timer timeout_watcher;
	ev_io io_watcher;
} composite_io_watcher;

typedef struct Sleep_watcher {
	int coroutine_id;
    ev_timer timer_watcher;
} Sleep_watcher;

typedef struct Sleep_abs_watcher {
	int coroutine_id;
    ev_periodic timer_watcher;
} Sleep_abs_watcher;

typedef struct Recv_watcher {
	http_parser parser;
	http_parser_settings parser_settings;
	int headers_table_index;
	composite_io_watcher cio_watcher;
} Recv_watcher;

//~ typedef struct Sigint_watcher {
	//~ int uthread_id;
	//~ ev_signal signal_watcher;
//~ } Sigint_watcher;


static int cl_destroy_composite_io_watcher (lua_State *L);

ev_loop *loop;
lua_State *lua_state;


void lua_stack_dump (lua_State *L) {
	printf("** stack dump:\n");

	int top = lua_gettop(L);
	for (int i = 1; i <= top; i ++) {
		printf("   %2i: ", i);

		int t = lua_type(L, i);
		switch (t) {
			case LUA_TSTRING: {
				printf("'%s'", lua_tostring(L, i));
				break;
			}
			case LUA_TBOOLEAN: {
				printf(lua_toboolean(L, i) ? "true" : "false");
				break;
			}
			case LUA_TNUMBER: {
				printf("%g", lua_tonumber(L, i));
				break;
			}
			default: {
				printf("(%s)", lua_typename(L, t));
				break;
			}
		}

		printf("\n");
	}
}


//for luajit ffi
void stop_ev_loop () {
	ev_break(EV_A_ EVBREAK_ALL);
}


static void cb_sigint (EV_P_ ev_signal *w, int revents) {
	printf("**SIGINT\n");

	lua_getfield(lua_state, LUA_REGISTRYINDEX, "shut_down");
	if (lua_pcall(lua_state, 0, 0, 0)) {
		printf("error running shut_down: %s\n", lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}

	//~ ev_break(EV_A_ EVBREAK_ALL);
}


static int lua_on_panic (lua_State *L) {
	printf("** Lua panic: %s\n", lua_tostring(L, -1));

	//TODO add traceback

	return 0;
}

static void create_lua_module_initializers_table (lua_State *L) {
	lua_newtable(L);
	lua_setglobal(L, "c_initializers");
}

void add_lua_module_initializer (lua_State *L, char *in_lua_name, lua_CFunction initialize) {
	lua_getglobal(L, "c_initializers");

	//TODO find out if it's safe not to save this array. check http://www.lua.org/source/5.1/lauxlib.c.html#luaI_openlib
	luaL_register(L, NULL, (const luaL_reg []){
		{in_lua_name, initialize},
		{NULL, NULL},
	});

	lua_pop(L, 1);
}


static void cb_sleep (EV_P_ ev_timer *w, int revents) {
	Sleep_watcher *watcher = (Sleep_watcher *)(((char *)w) - offsetof (Sleep_watcher, timer_watcher));

	lua_getfield(lua_state, LUA_REGISTRYINDEX, "plan_resume");
	lua_pushliteral(lua_state, "cb_sleep");
	lua_pushinteger(lua_state, watcher->coroutine_id);

	if (lua_pcall(lua_state, 2, 0, 0)) {
		printf("%s(): error running plan_resume: %s\n", __FUNCTION__, lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}
}
static void cb_sleep_abs (EV_P_ ev_periodic *w, int revents) {
	Sleep_abs_watcher *watcher = (Sleep_abs_watcher *)(((char *)w) - offsetof (Sleep_abs_watcher, timer_watcher));

	lua_getfield(lua_state, LUA_REGISTRYINDEX, "plan_resume");
	lua_pushliteral(lua_state, "cb_sleep_abs");
	lua_pushinteger(lua_state, watcher->coroutine_id);

	if (lua_pcall(lua_state, 2, 0, 0)) {
		printf("%s(): error running plan_resume: %s\n", __FUNCTION__, lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}
}

static int cl_destroy_sleep_watcher (lua_State *L) {
	Sleep_watcher *watcher = (Sleep_watcher *)lua_touserdata(L, lua_upvalueindex(1));
	assert(watcher != NULL);
	//~ printf("**cl_destroy_sleep_watcher\n");

	ev_timer_stop(loop, &(watcher->timer_watcher));

	free(watcher);

	return 0;
}
static int cl_destroy_sleep_abs_watcher (lua_State *L) {
	Sleep_abs_watcher *watcher = (Sleep_abs_watcher *)lua_touserdata(L, lua_upvalueindex(1));
	assert(watcher != NULL);
	//~ printf("**cl_destroy_sleep_watcher\n");

	ev_periodic_stop(loop, &(watcher->timer_watcher));

	free(watcher);

	return 0;
}

static int lua_mistress_sleep (lua_State *L) {
	int id = luaL_checknumber(L, 1);
	double seconds = luaL_checknumber(L, 2);

	int ret_num = 0;

	if (seconds < 1000000000) {
		Sleep_watcher *watcher = malloc(sizeof (Sleep_watcher));
		assert(watcher != NULL);
		watcher->coroutine_id = id;
		ev_timer_init(&(watcher->timer_watcher), cb_sleep, seconds, 0.);
		ev_timer_start(loop, &(watcher->timer_watcher));

		lua_pushlightuserdata(L, (void *)watcher);
		lua_pushcclosure(L, &cl_destroy_sleep_watcher, 1);
		++ret_num;
	} else {
		Sleep_abs_watcher *watcher = malloc(sizeof (Sleep_abs_watcher));
		assert(watcher != NULL);
		watcher->coroutine_id = id;
		ev_periodic_init(&(watcher->timer_watcher), cb_sleep_abs, seconds, 0, 0);
		ev_periodic_start(loop, &(watcher->timer_watcher));

		lua_pushlightuserdata(L, (void *)watcher);
		lua_pushcclosure(L, &cl_destroy_sleep_abs_watcher, 1);
		++ret_num;
	}

	return ret_num;
}


static int lua_register_plan_resume (lua_State *L) {
	luaL_checktype(L, 1, LUA_TFUNCTION);
	lua_setfield(L, LUA_REGISTRYINDEX, "plan_resume");
	return 0;
}

static int lua_register_shut_down (lua_State *L) {
	luaL_checktype(L, 1, LUA_TFUNCTION);
	lua_setfield(L, LUA_REGISTRYINDEX, "shut_down");
	return 0;
}

int lua_register_resume_active_sessions (lua_State *L) {
	luaL_checktype(L, 1, LUA_TFUNCTION);
	lua_setfield(L, LUA_REGISTRYINDEX, "resume_active_sessions");
	return 0;
}


static int hp_message_begin_cb (http_parser *parser) {
	//~ printf("**hp_message_begin_cb\n");

	lua_pushliteral(lua_state, "headers");  // 1
	lua_createtable(lua_state, 2 * 8, 0);  // 2  //prealloc for some header name-value pairs

    return 0;
}
static int hp_url_cb (http_parser *parser, const char *at, size_t length) {
	//~ printf("**hp_url_cb\n");
	Recv_watcher *watcher = (Recv_watcher *)(((char *)parser) - offsetof (Recv_watcher, parser));

	lua_pushliteral(lua_state, "url");
	lua_pushlstring(lua_state, at, length);
	lua_rawset(lua_state, -(1 + 2 + 2));  //result

	//~ lua_stack_dump(lua_state);
	//lua_pushlstring(lua_state, at, length);
	//lua_rawseti(lua_state, -2, ++(watcher->headers_table_index));

    return 0;
}

static int hp_header_field_cb (http_parser *parser, const char *at, size_t length) {
	//~ printf("**hp_header_field_cb\n");
	Recv_watcher *watcher = (Recv_watcher *)(((char *)parser) - offsetof (Recv_watcher, parser));

	lua_pushlstring(lua_state, at, length);
	lua_rawseti(lua_state, -2, ++(watcher->headers_table_index));

    return 0;
}
static int hp_header_value_cb (http_parser *parser, const char *at, size_t length) {
	//~ printf("**hp_header_value_cb\n");
	Recv_watcher *watcher = (Recv_watcher *)(((char *)parser) - offsetof (Recv_watcher, parser));

	if (memcmp(at, "gzip\r", strlen("gzip\r")) == 0) { //TODO not safe //TODO !!!!!!!!!!!!! \r (Accept-Encoding vs Content-Encoding ...)
		//printf("** is gzipped\n");
		lua_pushliteral(lua_state, "is_gzipped");
		lua_pushboolean(lua_state, 1);
		lua_rawset(lua_state, -(1 + 2 + 2));  //result
	}
	lua_pushlstring(lua_state, at, length);

	lua_rawseti(lua_state, -2, ++(watcher->headers_table_index));

    return 0;
}
static int hp_headers_complete_cb (http_parser *parser) {
	//~ printf("**hp_headers_complete_cb\n");
	lua_rawset(lua_state, -3);  //"headers", result

	lua_pushliteral(lua_state, "is_keepalive");
	lua_pushboolean(lua_state, http_should_keep_alive(parser));
	lua_rawset(lua_state, -3);

	lua_pushliteral(lua_state, "status_code");
	lua_pushinteger(lua_state, parser->status_code);
	lua_rawset(lua_state, -3);

    return 0;
}

#define RECV_SIZE 80 * 1024
//~ #define CHUNK 80 * 1024
#define CHUNK 16384
static int hp_body_cb (http_parser *parser, const char *at, size_t length) {
	//~ printf("  **hp_body_cb len=%d\n", length);
	//Recv_watcher *watcher = (Recv_watcher *)(((char *)parser) - offsetof (Recv_watcher, parser));

	lua_pushliteral(lua_state, "body");

	lua_rawget(lua_state, -2);
	if (lua_isnil(lua_state, -1)) {
		lua_pop(lua_state, 1);

		lua_pushliteral(lua_state, "body");

		lua_pushlstring(lua_state, at, length);

		lua_rawset(lua_state, -3);
	} else {
		lua_pushlstring(lua_state, at, length);
		lua_concat(lua_state, 2);

		lua_pushliteral(lua_state, "body");
		lua_insert(lua_state, -2); //swap

		lua_rawset(lua_state, -3);
	}

    return 0;
}

static int hp_stub_cb (http_parser *parser, const char *at, size_t length) {
	return 0;
}

static int hp_message_complete_cb (http_parser *parser) {
	//~ printf("**hp_message_complete_cb\n");

	lua_pushliteral(lua_state, "is_done");
	lua_pushboolean(lua_state, 1);
	lua_rawset(lua_state, -3);

    return 0;
}


static void cb_recv (EV_P_ ev_io *w, int revents) {
	Recv_watcher *watcher = (Recv_watcher *)(((char *)w) - offsetof (Recv_watcher, cio_watcher.io_watcher));
	//printf("**cb_recv fd %d\n", watcher->cio_watcher.io_watcher.fd);

	lua_getfield(lua_state, LUA_REGISTRYINDEX, "plan_resume");
	int arg_num = 0;

	lua_pushliteral(lua_state, "cb_recv");
	++arg_num;
	lua_pushinteger(lua_state, watcher->cio_watcher.coroutine_id);
	++arg_num;


	//size_t len = RECV_SIZE;
	size_t len = CHUNK;
	//char buffer[len];
	//char *buffer = malloc((len + 1) * sizeof (char));
	//char *buffer = malloc(len * sizeof (char));
	char *buffer = malloc(len);
    memset(buffer, 0, len);

	errno = 0;
	ssize_t got = recv(w->fd, buffer, len, 0);
	if (got == -1) {
		/*todo If no messages are available at the socket, the receive calls wait for a message to arrive, unless the socket is nonblocking (see fcntl(2)), in which case the value -1 is returned and the external variable  errno  is  set  to
       EAGAIN or EWOULDBLOCK.  The receive calls normally return any data available, up to the requested amount, rather than waiting for receipt of the full amount requested.*/
		lua_pushboolean(lua_state, 0);
		++arg_num;
		assert(errno);
		lua_pushstring(lua_state, strerror(errno));
		++arg_num;
		//~ printf("**errno after recv(): %d\n", errno);
		//~ perror("**error after recv()");
		//~ exit(EXIT_FAILURE);
	} else if (got < 0) {
		printf("failed to recv, got %zd\n", got);
		exit(EXIT_FAILURE);
	} else if (got == 0) {
		// result
		lua_newtable(lua_state);
		++arg_num;

		lua_pushliteral(lua_state, "closed");
		lua_pushboolean(lua_state, 1);
		lua_rawset(lua_state, -3);
	} else {
		//~ printf("**recved %i b, buf:\n%s\n", got, buffer);
		//~ printf("**recved %d b\n", got);

		// result
		lua_newtable(lua_state);
		++arg_num;

		lua_pushliteral(lua_state, "passed");
		ev_tstamp passed = ev_now(EV_A) - watcher->cio_watcher.started;
		lua_pushnumber(lua_state, passed);
		lua_rawset(lua_state, -3);

		//watcher->parser.data = (void *)&arg_num;


		//size_t recved = 0;
		//size_t recved = got;
		size_t nparsed = http_parser_execute(&(watcher->parser), &(watcher->parser_settings), buffer, got);
		//printf("**nparsed: %d\n", nparsed);
		free(buffer);
		//parser->flags |= F_CHUNKED
		//parser->content_length

		if (watcher->parser.upgrade) {
			printf("upgrading not implemented yet\n");
			exit(EXIT_FAILURE);
		} else if (nparsed != got) {
			printf("nparsed(%zd) != recved(%zd)\n", nparsed, got);

			lua_pushliteral(lua_state, "parse_failed");
			lua_pushboolean(lua_state, 1);
			lua_rawset(lua_state, -3);

			lua_pushliteral(lua_state, "body");
			lua_pushlstring(lua_state, buffer, got);
			lua_rawset(lua_state, -3);

			//~ FILE *fp = fopen("packet_dump.bin", "wb");
			//~ fwrite(buffer, 1, got, fp);
			//~ fclose(fp);
			//~ printf("**dumped to ./packet_dump.bin\n");
//~
			//~ printf("**recved %zd b, buf:\n%s\n", got, buffer);
			//~ exit(EXIT_FAILURE);
		}
	}

	int res_num = 0;
	if (lua_pcall(lua_state, arg_num, res_num, 0)) {
		printf("%s: failed to call plan_resume(): %s\n", __FUNCTION__, lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}
}

static void cb_recv_timeout (EV_P_ ev_timer *w, int revents) {
	//~ printf("**cb_recv_timeout\n");
	composite_io_watcher *watchers = (composite_io_watcher *)(((char *)w) - offsetof (composite_io_watcher, timeout_watcher));
	//ev_io_stop(loop, &(watchers->io_watcher));

	lua_getfield(lua_state, LUA_REGISTRYINDEX, "plan_resume");
	int arg_num = 0;


	lua_pushliteral(lua_state, "cb_recv_timeout");
	++arg_num;

	lua_pushinteger(lua_state, watchers->coroutine_id);
	++arg_num;

	//~ lua_pushnil(lua_state);
	lua_pushboolean(lua_state, 0);
	++arg_num;
	lua_pushliteral(lua_state, "timeout");
	++arg_num;


	int res_num = 0;
	if (lua_pcall(lua_state, arg_num, res_num, 0)) {
		printf("error running plan_resume: %s\n", lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}
}

static int cl_destroy_recv_watcher (lua_State *L) {
	Recv_watcher *watcher = (Recv_watcher *)lua_touserdata(L, lua_upvalueindex(1));
	assert(watcher != NULL);
	//~ printf("**cl_destroy_recv_watcher fd%d\n", watcher->cio_watcher.io_watcher.fd);

	ev_timer_stop(loop, &(watcher->cio_watcher.timeout_watcher));
	ev_io_stop(loop, &(watcher->cio_watcher.io_watcher));

	free(watcher);

	return 0;
}

static int lua_mistress_receive (lua_State *L) {
	int id = luaL_checkint(L, 1);
	int fd = luaL_checkint(L, 2);
	assert(lua_isboolean(L, 3));
	int do_fetch_body = lua_toboolean(L, 3);
	double timeout = luaL_checknumber(L, 4);
	//printf("**%f\n", timeout);
	//~ printf("**lua_mistress_receive id %d fd %d\n", id, fd);
	int is_req = luaL_optint(L, 5, 0);


	Recv_watcher *watcher = malloc(sizeof (Recv_watcher));
	watcher->headers_table_index = 0;
	watcher->cio_watcher.coroutine_id = id;
	watcher->cio_watcher.started = ev_now(EV_A);

	ev_io_init(&(watcher->cio_watcher.io_watcher), cb_recv, fd, EV_READ);
	ev_io_start(loop, &(watcher->cio_watcher.io_watcher));


	ev_timer_init(&(watcher->cio_watcher.timeout_watcher), cb_recv_timeout, timeout, 0.);
	if (timeout) {
		ev_timer_start(loop, &(watcher->cio_watcher.timeout_watcher));
	}


	http_parser_init(&(watcher->parser), is_req ? HTTP_REQUEST : HTTP_RESPONSE);
	watcher->parser_settings.on_message_begin = hp_message_begin_cb;
	watcher->parser_settings.on_url = hp_url_cb;
	watcher->parser_settings.on_header_field = hp_header_field_cb;
	watcher->parser_settings.on_header_value = hp_header_value_cb;
	watcher->parser_settings.on_headers_complete = hp_headers_complete_cb;
	if (do_fetch_body) {
		watcher->parser_settings.on_body = hp_body_cb;
	} else {
		watcher->parser_settings.on_body = hp_stub_cb;
	}
	watcher->parser_settings.on_message_complete = hp_message_complete_cb;


	int ret_num = 0;
	lua_pushlightuserdata(L, (void *)watcher);
	lua_pushcclosure(L, &cl_destroy_recv_watcher, 1);
	++ret_num;

	return ret_num;
}


static void cb_send_ready (EV_P_ ev_io *w, int revents) {
	composite_io_watcher *watchers = (composite_io_watcher *)(((char *)w) - offsetof (composite_io_watcher, io_watcher));
	
	int ern;
	socklen_t ern_len = sizeof (ern);
	if (getsockopt(w->fd, SOL_SOCKET, SO_ERROR, &ern, &ern_len)) {
		printf("**failed to getsockopt at cb_send_ready\n");
		exit(EXIT_FAILURE);
	}
	if (ern) {
		printf("**error at cb_send_ready: %i\n", ern);
		exit(EXIT_FAILURE);
	}

	lua_getfield(lua_state, LUA_REGISTRYINDEX, "plan_resume");
	int arg_num = 0;

	lua_pushliteral(lua_state, "cb_send_ready");
	++arg_num;

	lua_pushinteger(lua_state, watchers->coroutine_id);
	++arg_num;

	int res_num = 0;
	if (lua_pcall(lua_state, arg_num, res_num, 0)) {
		printf("error running plan_resume at cb_send_ready: %s\n", lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}
}

static void cb_send_timeout (EV_P_ ev_timer *w, int _revents) {
	composite_io_watcher *watchers = (composite_io_watcher *)(((char *)w) - offsetof (composite_io_watcher, timeout_watcher));

	lua_getfield(lua_state, LUA_REGISTRYINDEX, "plan_resume");

	lua_pushliteral(lua_state, "cb_send_timeout");
	
	lua_pushinteger(lua_state, watchers->coroutine_id);

	lua_pushboolean(lua_state, true);

	if (lua_pcall(lua_state, 3, 0, 0)) { //args, results
		printf("error running plan_resume at cb_send_timeout: %s\n", lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}
}

static int lua_mistress_send (lua_State *L) {
	int fd = luaL_checkint(L, 1);
	size_t len;
	const char *buffer = luaL_checklstring(L, 2, &len);
	int coroutine_id = luaL_optinteger(L, 3, 0);
	int pos = luaL_optinteger(L, 4, 0);

	int ret_num = 0;

	ssize_t total_sent = pos;
	ssize_t bytes_left = len - pos;
	while (total_sent < len) {
		errno = 0;
		ssize_t bytes_sent = send(fd, buffer + total_sent, bytes_left, MSG_NOSIGNAL);
		if (bytes_sent < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				assert(coroutine_id > 0);

				lua_pushnumber(L, 0);
				++ret_num;
				lua_pushnumber(L, total_sent - pos);
				++ret_num;

				struct composite_io_watcher *watchers = malloc(sizeof (struct composite_io_watcher));
				watchers->coroutine_id = coroutine_id;
				watchers->started = ev_now(EV_A);
				ev_timer_init(&(watchers->timeout_watcher), cb_send_timeout, 15, 0.);
				ev_timer_start(loop, &(watchers->timeout_watcher));
				ev_io_init(&(watchers->io_watcher), cb_send_ready, fd, EV_WRITE);
				ev_io_start(loop, &(watchers->io_watcher));

				lua_pushlightuserdata(L, (void *)watchers);
				lua_pushcclosure(L, &cl_destroy_composite_io_watcher, 1);
				++ret_num;
				return ret_num;
			}
			if (errno == EPIPE) {
				lua_pushinteger(L, errno);
				++ret_num;
				return ret_num;
			} else {
				printf("**errno after send(): %d\n", errno);
				perror("**error after send()");
				exit(EXIT_FAILURE);
			}
		// } else if (bytes_sent != len) {
			// printf("fd %i sent %zd (%zd of %zd)\n", fd, bytes_sent, total_sent + bytes_sent, len);
			//exit(EXIT_FAILURE);
		}

		total_sent += bytes_sent;
        bytes_left -= bytes_sent;
	}

	lua_pushboolean(L, false);
	++ret_num;
	lua_pushnumber(L, total_sent - pos);
	++ret_num;

	return ret_num;
}

static int lua_mistress_now (lua_State *L) {
	ev_tstamp now = ev_now(EV_A);
	lua_pushnumber(L, now);
	return 1;
}

//http://zlib.net/zlib_how.html
#define CHUNK1 16384
static int lua_mistress_zip (lua_State *L) {
	size_t length;
	const char *at = luaL_checklstring(L, 1, &length);

	luaL_Buffer b;
	luaL_buffinit(L, &b);

	//----
	int ret, flush;
    unsigned have;
    z_stream strm;
    unsigned char in[CHUNK1];
    unsigned char out[CHUNK1];

	/* allocate deflate state */
    strm.zalloc = Z_NULL;
    strm.zfree = Z_NULL;
    strm.opaque = Z_NULL;
    ret = deflateInit(&strm, Z_DEFAULT_COMPRESSION);
    if (ret != Z_OK)
        return ret;

	/* compress until end of file */
    do {
        //strm.avail_in = fread(in, 1, CHUNK1, source);
        strm.avail_in = length;
        //if (ferror(source)) {
        //    (void)deflateEnd(&strm);
        //    return Z_ERRNO;
        //}
        //flush = feof(source) ? Z_FINISH : Z_NO_FLUSH;
        flush = Z_FINISH;
        //strm.next_in = in;
        strm.next_in = (Bytef *)at; //not sure about const
		/* run deflate() on input until output buffer not full, finish
           compression if all of source has been read in */
        do {
			strm.avail_out = CHUNK1;
            strm.next_out = out;

			ret = deflate(&strm, flush);    /* no bad return value */
            assert(ret != Z_STREAM_ERROR);  /* state not clobbered */

			have = CHUNK1 - strm.avail_out;
            //if (fwrite(out, 1, have, dest) != have || ferror(dest)) {
            //    (void)deflateEnd(&strm);
            //    return Z_ERRNO;
            //}
			luaL_addlstring(&b, out, have);
		} while (strm.avail_out == 0);
        assert(strm.avail_in == 0);     /* all input will be used */
		/* done when last data in file processed */
    } while (flush != Z_FINISH);
    assert(ret == Z_STREAM_END);        /* stream will be complete */

	/* clean up and return */
    (void)deflateEnd(&strm);
    //return Z_OK;
	//--------

	luaL_pushresult(&b);

	return 1;
}

static int lua_mistress_gunzip (lua_State *L) {
	size_t length;
	const char *at = luaL_checklstring(L, 1, &length);
	//~ printf("*********%s\n", at);
	//~ printf("** lua_mistress_gunzip %i\n", length);

	/*size_t len = 80 * 1024;
	char buffer[len];
	memset(buffer, 0, len);
	uLongf destlen = 0;
	int ret = uncompress((Bytef *)buffer, &destlen, (const Bytef *)at, (uLong) length);
	printf("*********%d   %s\n", ret, buffer);
	printf("*********%d\n", ret == Z_DATA_ERROR);*/
	size_t len = CHUNK;
	//~ size_t len = 1024 * 1024;
	//~ char dest[len];

	luaL_Buffer b;
	luaL_buffinit(L, &b);


	//////////////////////http://zlib.net/zlib_how.html
	int ret;
	unsigned have;
	z_stream strm;
	//~ unsigned char in[CHUNK];
	unsigned char out[len];
	unsigned char rez[len];

	strm.zalloc = Z_NULL;
	strm.zfree = Z_NULL;
	strm.opaque = Z_NULL;
	strm.avail_in = 0;
	strm.next_in = Z_NULL;
	ret = inflateInit2(&strm, MAX_WBITS + 16);  //http://zlib.net/manual.html#Advanced "windowBits can also be greater than 15 for optional gzip decoding. Add 32 to windowBits to enable zlib and gzip decoding with automatic header detection, or add 16 to decode only the gzip format (the zlib format will return a Z_DATA_ERROR). If a gzip stream is being decoded, strm->adler is a crc32 instead of an adler32. "
	if (ret != Z_OK) {
		printf("**ret != Z_OK\n");
		exit(EXIT_FAILURE);
	}
	do {
		//strm.avail_in = fread(in, 1, CHUNK, source);
		strm.avail_in = length;
		/*if (ferror(source)) {
			(void)inflateEnd(&strm);
			return Z_ERRNO;
		}*/
		if (strm.avail_in == 0)
			break;
		//strm.next_in = in;
		strm.next_in = (Bytef *)at; //not sure about const
		do {
			strm.avail_out = CHUNK;
			//~ strm.next_out = (char *)(out + have);
			strm.next_out = out;
			//printf("**#@@@@@@@@@@@@ %s\n", out);
			ret = inflate(&strm, Z_NO_FLUSH);
			assert(ret != Z_STREAM_ERROR);  /* state not clobbered */
			switch (ret) {
				case Z_NEED_DICT:
					printf("**Z_NEED_DICT\n");
					ret = Z_DATA_ERROR;     /* and fall through */
				case Z_DATA_ERROR:
					(void)inflateEnd(&strm);

					printf("**Z_DATA_ERROR\n");
					printf("*********%s\n", at);
					exit(EXIT_FAILURE);
				case Z_MEM_ERROR:
					(void)inflateEnd(&strm);
					printf("**Z_MEM_ERROR\n");
					exit(EXIT_FAILURE);
			}

			have = CHUNK - strm.avail_out;
			luaL_addlstring(&b, out, have);
			/*if (fwrite(out, 1, have, stdout) != have || ferror(stdout)) {
				(void)inflateEnd(&strm);
				 printf("**fwrite\n");
				exit(EXIT_FAILURE);
			}*/
		} while (strm.avail_out == 0);
	} while (ret != Z_STREAM_END);

	(void)inflateEnd(&strm);
	//return ret == Z_STREAM_END ? Z_OK : Z_DATA_ERROR;

	//~ lua_pushlstring(L, out, have);
	luaL_pushresult(&b);

	return 1;
}


static void cb_connect (EV_P_ ev_io *w, int revents) {
	composite_io_watcher *watchers = (composite_io_watcher *)(((char *)w) - offsetof (composite_io_watcher, io_watcher));
	//printf("**cb_connect fd %d\n", w->fd);
	//http://developerweb.net/viewtopic.php?id=3196
	ev_tstamp passed = ev_now(EV_A) - watchers->started;

	int ern;
	socklen_t ern_len = sizeof (ern);
	if (getsockopt(w->fd, SOL_SOCKET, SO_ERROR, &ern, &ern_len)) {
		printf("**failed to getsockopt at cb_connect\n");
		exit(EXIT_FAILURE);
	}
	//btw ern can be 0 even on ECONNREFUSED, and yo you'll get ECONNREFUSED only after send
	/*if (ern) {
		if (ern == ECONNREFUSED) {
			printf("**ECONNREFUSED\n");
		} else {
			printf("**socket error at cb_connect: %d\n", ern);
			exit(EXIT_FAILURE);
		}
	}*/

	lua_getfield(lua_state, LUA_REGISTRYINDEX, "plan_resume");
	int arg_num = 0;

	lua_pushliteral(lua_state, "cb_connect");
	++arg_num;

	lua_pushinteger(lua_state, watchers->coroutine_id);
	++arg_num;
	if (ern) {
		//lua_pushnil(lua_state);  // instead of fd
		lua_pushinteger(lua_state, 0);
		++arg_num;
		lua_pushinteger(lua_state, ern);
		++arg_num;
		//TODO push strerror(ern)
	} else {
		lua_pushinteger(lua_state, w->fd);
		++arg_num;
		lua_pushnumber(lua_state, passed);
		++arg_num;
	}

	//lua_stack_dump(lua_state);

	int res_num = 0;
	if (lua_pcall(lua_state, arg_num, res_num, 0)) {
		printf("error running plan_resume at cb_connect: %s\n", lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}
}

static void cb_connect_timeout (EV_P_ ev_timer *w, int _revents) {
	// char buff[100];
	// time_t now = time (0);
	// strftime (buff, 100, "%Y-%m-%d %H:%M:%S.000", localtime (&now));
	// printf("** %s cb_connect_timeout\n", buff);
	
	composite_io_watcher *watchers = (composite_io_watcher *)(((char *)w) - offsetof (composite_io_watcher, timeout_watcher));

	lua_getfield(lua_state, LUA_REGISTRYINDEX, "plan_resume");

	lua_pushliteral(lua_state, "cb_connect_timeout");
	//~ ++arg_num;

	lua_pushinteger(lua_state, watchers->coroutine_id);
	lua_pushinteger(lua_state, 0);  // instead of fd

	if (lua_pcall(lua_state, 3, 0, 0)) { //args, results
		printf("error running plan_resume at cb_connect_timeout: %s\n", lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}
}

static int cl_destroy_composite_io_watcher (lua_State *L) {
	composite_io_watcher *watcher = (composite_io_watcher *)lua_touserdata(L, lua_upvalueindex(1));
	assert(watcher != NULL);
	//~ printf("**cl_destroy_composite_io_watcher fd%d\n", watcher->io_watcher.fd);

	ev_timer_stop(loop, &(watcher->timeout_watcher));
	ev_io_stop(loop, &(watcher->io_watcher));

	free(watcher);

	return 0;
}

static int cl_close_socket (lua_State *L) {
	int fd = luaL_checkint(L, lua_upvalueindex(1));
	//~ int fd = lua_tointeger(L, lua_upvalueindex(1));
	//printf("**cl_close_socket %d\n", fd);

	errno = 0;
	int res = close(fd);
	if (res != 0) {
		assert(res == -1);
		printf("**fd: %i\n", fd);
		perror("**failed to close fd");
		exit(EXIT_FAILURE);
	}

	return 0;
}

static void set_nonblock (int fd) {
	int flags = fcntl(fd, F_GETFL, 0);
	errno = 0;
	if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1) {
		perror("**error on setting socket flags");
		exit(EXIT_FAILURE);
	}
}

void set_sock_opt (int fd, int level, int optname, int value) {
	errno = 0;
	if (setsockopt(fd, level, optname, (const char *)&value, sizeof (value))) {
		perror("**setsockopt failed");
		exit(EXIT_FAILURE);
	}
}

static int lua_mistress_connect (lua_State *L) {
	int coroutine_id = luaL_checkint(L, 1);
	//printf("**lua_mistress_connect coroutine_id %d\n", coroutine_id);

	const char *remote_addr = luaL_checkstring(L, 2);
	int remote_port = luaL_checkint(L, 3);
	//int local_addr = htonl(INADDR_ANY);
	const char *local_addr = luaL_checkstring(L, 4);
	int local_port = luaL_checkint(L, 5);
	double conn_timeout = luaL_checknumber(L, 6);


	int fd = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (fd < 0) {
		perror("**socket error at lua_mistress_connect");
		exit(EXIT_FAILURE);
	}

	set_nonblock(fd);


	set_sock_opt(fd, IPPROTO_TCP, TCP_NODELAY, 1);
	set_sock_opt(fd, SOL_SOCKET, SO_REUSEADDR, 1);
	set_sock_opt(fd, SOL_SOCKET, SO_KEEPALIVE, 0);

	//SO_RCVBUF
	//SO_SNDBUF

	// bind a socket to a device name (might not work on all systems):
	//optval2 = "eth1"; // 4 bytes long, so 4, below:
	//setsockopt(s2, SOL_SOCKET, SO_BINDTODEVICE, optval2, 4);


	struct sockaddr_in addr_local;
    memset(&addr_local, 0, sizeof (struct sockaddr_in));
    addr_local.sin_family = AF_INET;
    addr_local.sin_port = htons(local_port);
    addr_local.sin_addr.s_addr = inet_addr(local_addr);
    if (bind(fd, (struct sockaddr *)&addr_local, sizeof (struct sockaddr)) == -1) {
		perror("bind error");
		exit(EXIT_FAILURE);
	}

	struct sockaddr_in addr_remote;
    memset(&addr_remote, 0, sizeof (struct sockaddr_in));
    addr_remote.sin_family = AF_INET;
    addr_remote.sin_port = htons(remote_port);
    addr_remote.sin_addr.s_addr = inet_addr(remote_addr);



	errno = 0;
	int ret = connect(fd, (struct sockaddr *)&addr_remote, sizeof (struct sockaddr));
	if (ret == -1 && errno != EINPROGRESS) {
		perror("connect error");
		errno = 0;
		close(fd);
		exit(EXIT_FAILURE);
	}


	struct composite_io_watcher *watchers = malloc(sizeof (struct composite_io_watcher));
	watchers->coroutine_id = coroutine_id;
	watchers->started = ev_now(EV_A);
	ev_timer_init(&(watchers->timeout_watcher), cb_connect_timeout, conn_timeout, 0.);
	ev_timer_start(loop, &(watchers->timeout_watcher));

	ev_io_init(&(watchers->io_watcher), cb_connect, fd, EV_WRITE);
	ev_io_start(loop, &(watchers->io_watcher));


	int ret_num = 0;
	lua_pushlightuserdata(L, (void *)watchers);
	lua_pushcclosure(L, &cl_destroy_composite_io_watcher, 1);
	++ret_num;

	lua_pushinteger(L, fd);
	lua_pushcclosure(L, &cl_close_socket, 1);
	++ret_num;

	return ret_num;
}


static void cb_accept (EV_P_ ev_io *w, int revents) {
	composite_io_watcher *watchers = (composite_io_watcher *)(((char *)w) - offsetof (composite_io_watcher, io_watcher));

	lua_getfield(lua_state, LUA_REGISTRYINDEX, "plan_resume");
	int arg_num = 0;

	lua_pushliteral(lua_state, "cb_accept");
	++arg_num;
	lua_pushinteger(lua_state, watchers->coroutine_id);
	++arg_num;

	while (true) {
		struct sockaddr_in client_addr;
		socklen_t client_addr_len = sizeof (client_addr);

		errno = 0;
		int fd = accept(w->fd, (struct sockaddr *)&client_addr, &client_addr_len);
		if (fd == -1) {
			if (errno == EAGAIN) {
				break;
			} else {
				perror("accept error");
				errno = 0;
				exit(EXIT_FAILURE);
			}
		}

		lua_pushinteger(lua_state, fd);
		++arg_num;

		//printf("%s\n", inet_ntoa(client_addr.sin_addr));
	}

	int res_num = 0;
	if (lua_pcall(lua_state, arg_num, res_num, 0)) {
		printf("error running plan_resume at cb_accept: %s\n", lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}
}


static int script_accept (lua_State *L) {
	int uthread_id = luaL_checkint(L, 1);
	int listen_fd = luaL_checkint(L, 2);

	composite_io_watcher *watchers = malloc(sizeof (composite_io_watcher));
	watchers->coroutine_id = uthread_id;
	ev_io_init(&(watchers->io_watcher), cb_accept, listen_fd, EV_READ);
	ev_io_start(loop, &(watchers->io_watcher));
	ev_timer_init(&(watchers->timeout_watcher), cb_sleep, 0, 0.);  //TODO this is crutch to prevent crash in cl_destroy_composite_io_watcher

	int ret_num = 0;
	lua_pushlightuserdata(L, (void *)watchers);
	lua_pushcclosure(L, &cl_destroy_composite_io_watcher, 1);
	++ret_num;

	return ret_num;
}

//ffi
int script_listen (int port, int backlog) {
	int fd = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (fd == -1) {
		perror("socket creation error");
		exit(EXIT_FAILURE);
	}

	set_nonblock(fd);

	set_sock_opt(fd, IPPROTO_TCP, TCP_NODELAY, 1);
	set_sock_opt(fd, SOL_SOCKET, SO_REUSEADDR, 1);
	set_sock_opt(fd, SOL_SOCKET, SO_KEEPALIVE, 1);

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof (addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(port);
	addr.sin_addr.s_addr = INADDR_ANY;

	if (bind(fd, (struct sockaddr *)&addr, sizeof (addr))) {
		perror("bind error");
		exit(EXIT_FAILURE);
	}

	if (listen(fd, backlog)) {
		perror("listen error");
		exit(EXIT_FAILURE);
	}

	return fd;
}

static const struct luaL_Reg lua_mistress_functions [] = {
	{"register_plan_resume", lua_register_plan_resume},
	{"register_resume_active_sessions", lua_register_resume_active_sessions},
	{"register_shut_down", lua_register_shut_down},

	{"sleep", lua_mistress_sleep},
	{"receive", lua_mistress_receive},
	{"connect", lua_mistress_connect},
	{"accept", script_accept},

	{"send", lua_mistress_send},
	{"gunzip", lua_mistress_gunzip},
	{"zip", lua_mistress_zip},
	{"now", lua_mistress_now},

	{NULL, NULL}
};

static int mistress_init_lua (lua_State *L) {
	luaL_checktype (L, 1, LUA_TTABLE);
	luaL_register(L, NULL, lua_mistress_functions);

	return 0;
}

// triggers even after ^c
static void cb_prepare (EV_P_ ev_prepare *prepare, int revents) {
	//~ printf("cb_prepare\n");

	lua_getfield(lua_state, LUA_REGISTRYINDEX, "resume_active_sessions");

	int res = lua_pcall(lua_state, 0, 0, 0); //args, results
	if (res) {
		assert(res == LUA_ERRRUN);
		printf("error running resume_active_sessions at cb_prepare: %s\n", lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}
}

int main (int argc, char *argv[]) {
	// e.g. for cookie 'expires' parsing (for mktime). working with local tz is bad anyway
	setenv("TZ", "UTC", 1);
	tzset();


	loop = ev_default_loop(EVFLAG_AUTO);
	if (! loop) {
		printf("could not initialise libev, bad $LIBEV_FLAGS in environment?\n");
		return EXIT_FAILURE;
	}
	unsigned int backend = ev_backend(loop);
	if (backend != EVBACKEND_EPOLL) {
		printf("**WARNING using non-epoll backend %d\n", backend);
	}

	//---
	//use ev_set_userdata
	lua_state = luaL_newstate();
	assert(lua_state != NULL);
	lua_CFunction _old = lua_atpanic(lua_state, lua_on_panic);
	luaL_openlibs(lua_state);

	create_lua_module_initializers_table(lua_state);
	add_lua_module_initializer(lua_state, "mistress", mistress_init_lua);


	lua_createtable(lua_state, argc, 0);
	for(int ai; ai < argc; ++ai) {
		lua_pushstring(lua_state, argv[ai]);
		lua_rawseti(lua_state, -2, ai + 1);
	}
	lua_setglobal(lua_state, "ARGV");

	lua_pushliteral(lua_state, LUA_SRC_PATH);
	lua_setglobal(lua_state, "LUA_SRC_PATH");

	lua_pushboolean(lua_state, LUA_USE_LUAJIT);
	lua_setglobal(lua_state, "LUA_USE_LUAJIT");


	if (luaL_dofile(lua_state, LUA_SRC_PATH"/mistress/init.lua")) {
		printf("failed to load init.lua: %s\n", lua_tostring(lua_state, -1));
		exit(EXIT_FAILURE);
	}

	//~ lua_stack_dump(lua_state);
	//---


	ev_prepare prepare;
	ev_prepare_init(&prepare, cb_prepare);
	ev_prepare_start(loop, &prepare);


	ev_signal sigint_watcher;
	ev_signal_init(&sigint_watcher, cb_sigint, SIGINT);
	ev_signal_start(loop, &sigint_watcher);


	ev_run(loop, 0);


	printf("**exiting\n");
	return EXIT_SUCCESS;
}
