include ../../defines.mk

PERLSOURCE =   \
	VZDump.pm \

all:

.PHONY: clean
clean:
	rm -rf *~

.PHONY: install
install: ${PERLSOURCE}
	install -d ${PERLLIBDIR}/PVE/Jobs
	install -m 0644 ${PERLSOURCE} ${PERLLIBDIR}/PVE/Jobs
