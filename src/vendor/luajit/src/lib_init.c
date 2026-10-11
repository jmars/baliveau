/*
** Library initialization.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Major parts taken verbatim from the Lua interpreter.
** Copyright (C) 1994-2008 Lua.org, PUC-Rio. See Copyright Notice in lua.h
*/

#define lib_init_c
#define LUA_LIB

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_arch.h"

/*
** CAPABILITY BOUND (fx-harness, 2026-10-09) -- the guest Lua surface is the
** nine entries below, reduced from upstream's ten:
**
**   debug     dropped outright.  It is reflection that weakens static reading
**             of guest bytecode, and debug.debug() drops an interactive REPL
**             onto stdin -- console pollution in a guest.  With this entry
**             gone nothing references luaopen_debug, so lib_debug.o is not
**             linked at all from the library archive.
**
**   package   REDUCED, NOT DROPPED.  In Lua 5.1 require() is installed BY the
**             package library (src/lib_package.c, package_global[]), so
**             deleting luaopen_package would also delete require -- and
**             require must keep working for the preloads: luaopen_jit
**             pre-registers "jit.util" and "jit.profile" into package.preload
**             (src/lib_jit.c).  luaopen_package_bounded() below opens the
**             real library and strips the filesystem-facing half: no
**             loadlib/searchpath (dlopen), no path/cpath, no module/seeall,
**             and only the preload loader left in package.loaders.
**
**   io/os     admitted DELIBERATELY: this pair is the filesystem reach the
**             guest is granted.  os.execute/io.popen need /bin/sh and the
**             guest image does not ship one -- that claim is about the GUEST
**             environment and is asserted by the guest-only arm of
**             tests/luajit-audit.sh, never on a host that has /bin/sh.
**
**   coroutine is not an entry of its own: luaopen_base registers it
**             (src/lib_base.c, LJ_LIB_REG(L, LUA_COLIBNAME, coroutine)).
**
** The audit that proves this surface is tests/luajit-audit.sh (arm 1).
*/

/*
** Open the real package library, then strip it down to require + the module
** tables.  What survives: global require, package.preload, package.loaded and
** package.loaders[1] (the preload loader -- require() stops at the first nil
** entry, src/lib_package.c lj_cf_package_require, so truncating the table ends
** the filesystem module search).  What is removed: package.loadlib and
** package.searchpath (dlopen + file search), package.path/cpath (the search
** paths), package.seeall and global module (the other half of the 5.1 module
** system), and package.config (path templates for the search that no longer
** exists; also leaks build configuration).  The stripped C functions stay
** linked but are unreachable from Lua -- the bound is the SURFACE, and it is
** asserted by tests/luajit-audit.sh, not here.
*/
static int luaopen_package_bounded(lua_State *L)
{
  static const char *const stripped[] = {
    "path", "cpath", "loadlib", "searchpath", "seeall", "config",
    "searchers",	/* LJ_52 alias for the loaders table */
    NULL
  };
  int i;
  luaopen_package(L);		/* leaves the package table on the stack */
  for (i = 0; stripped[i] != NULL; i++) {
    lua_pushnil(L);
    lua_setfield(L, -2, stripped[i]);
  }
  lua_getfield(L, -1, "loaders");	/* upstream installs 4: package_loaders[] */
  for (i = 2; i <= 4; i++) {	/* keep only the preload loader at [1] */
    lua_pushnil(L);
    lua_rawseti(L, -2, i);
  }
  lua_pop(L, 1);
  lua_pushnil(L);
  lua_setglobal(L, "module");
  lua_pop(L, 1);		/* the package table */
  return 0;
}

static const luaL_Reg lj_lib_load[] = {
  { "",			luaopen_base },
  { LUA_LOADLIBNAME,	luaopen_package_bounded },
  { LUA_TABLIBNAME,	luaopen_table },
  { LUA_IOLIBNAME,	luaopen_io },
  { LUA_OSLIBNAME,	luaopen_os },
  { LUA_STRLIBNAME,	luaopen_string },
  { LUA_MATHLIBNAME,	luaopen_math },
  { LUA_BITLIBNAME,	luaopen_bit },
  { LUA_JITLIBNAME,	luaopen_jit },
  { NULL,		NULL }
};

static const luaL_Reg lj_lib_preload[] = {
#if LJ_HASFFI
  { LUA_FFILIBNAME,	luaopen_ffi },
#endif
  { NULL,		NULL }
};

LUALIB_API void luaL_openlibs(lua_State *L)
{
  const luaL_Reg *lib;
  for (lib = lj_lib_load; lib->func; lib++) {
    lua_pushcfunction(L, lib->func);
    lua_pushstring(L, lib->name);
    lua_call(L, 1, 0);
  }
  luaL_findtable(L, LUA_REGISTRYINDEX, "_PRELOAD",
		 sizeof(lj_lib_preload)/sizeof(lj_lib_preload[0])-1);
  for (lib = lj_lib_preload; lib->func; lib++) {
    lua_pushcfunction(L, lib->func);
    lua_setfield(L, -2, lib->name);
  }
  lua_pop(L, 1);
}

