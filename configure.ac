AC_INIT([update-repos], [1.0], [qdlacz@gmail.com])
AC_CONFIG_SRCDIR([update-repos.in])
AC_CONFIG_AUX_DIR([build])
AM_INIT_AUTOMAKE([silent-rules])
AC_ARG_VAR([PERL], [path to perl])
AC_PROG_SED
AC_PATH_PROGS(PERL, [perl perl5])
if test -z "$PERL"
then
  AC_MSG_ERROR([perl not found])
fi

AC_CONFIG_COMMANDS([chmod], [chmod a+x update-repos])
AC_CONFIG_FILES([Makefile
                 update-repos])
AC_OUTPUT
