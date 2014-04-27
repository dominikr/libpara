compile:
	echo nothing to do

install:
	install -d			$(DESTDIR)/usr/lib
	install -m 644 libpara.sh	$(DESTDIR)/usr/lib
