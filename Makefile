ROOT := $(shell pwd)

.PHONY: test build install clean

test:
	ros run -e '(progn (push #p"$(ROOT)/" asdf:*central-registry*) (ql:quickload :allisp/tests :silent t))' \
	        -e '(uiop:quit (if (uiop:symbol-call :fiveam :run! :allisp) 0 1))'

build: dist/allisp

dist/allisp: allisp.asd src/*.lisp
	mkdir -p dist
	ros run -e '(progn (push #p"$(ROOT)/" asdf:*central-registry*) (ql:quickload :allisp :silent t))' \
	        -e '(sb-ext:save-lisp-and-die "dist/allisp" :executable t :save-runtime-options t :toplevel (lambda () (allisp:main (uiop:command-line-arguments))))'

install:
	mkdir -p $(HOME)/.local/bin
	ln -sf $(ROOT)/bin/allisp $(HOME)/.local/bin/allisp

clean:
	rm -rf dist
