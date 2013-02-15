NAME=perl-Billing-Payment-IPPay
VERSION=0.1.0
MAINTAINER=mattcreenan@gmail.com
PERLDOC=`which perldoc`

.PHONY: package
package:
	perl -I lib $(PERLDOC) -o pod Billing::Payment::IPPay > README.pod
	perl -I lib $(PERLDOC) -o plain Billing::Payment::IPPay > README
	perl -MPod::Markdown -e 'my $$parser = Pod::Markdown->new; $$parser->parse_from_filehandle(\*STDIN); print $$parser->as_markdown;' < README.pod > README.md
