// Command fm-query is the matcher behind the interactive search (fm_rg.sh)
// and its preview (fm_preview.sh), so the search, the list and the preview
// share one parser and one matcher:
//
//	fm-query prefilter QUERY     # the regex fm_rg.sh hands rg
//	fm-query rows QUERY  <rg     # the matching lines, as fm_rg.sh's rows
//	fm-query mark QUERY  <text   # the preview, the query's terms reverse-videoed
//
// The query is fzf's extended-search syntax, matched as fzf 0.74 matches it:
// whitespace separates AND terms; a bare term is fuzzy ("cfg" finds
// "config"); 'term is an exact substring and 'term' an exact word; ^term and
// term$ anchor to the start and end of the line, past its surrounding
// whitespace; !term excludes (!'term fuzzily); a lone | ORs the terms on either
// side of it; "foo\ bar" is one term holding a space; a Latin letter finds its
// accented forms unless the term holds one. One difference, the header's
// "global smart-case": any ASCII uppercase letter makes the whole query
// case-sensitive, where fzf decides per term.
//
// rg only narrows the search, with one condition every matching line meets
// (see prefilter); rows applies the whole query in Go, in linear time, so no
// regex engine limit can drop a file. A query without a positive term (empty,
// or exclusions only) has no prefilter, and fm_rg.sh lists nothing rather than
// every line of the tree.
package main

import (
	"errors"
	"fmt"
	"io"
	"os"
)

var errUsage = errors.New("usage: fm-query prefilter|rows|mark QUERY")

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "fm-query:", err)
		os.Exit(1)
	}
}

// run is the command line: an older fm_rg.sh's one-argument form is refused,
// as is anything but a subcommand and its query.
func run(args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) != 2 {
		return errUsage
	}
	switch args[0] {
	case "prefilter":
		if re, ok := parse(args[1]).prefilter(); ok {
			_, err := fmt.Fprintln(stdout, re)
			return err
		}
		return nil
	case "rows":
		return rows(stdin, stdout, args[1])
	case "mark":
		return mark(stdin, stdout, args[1])
	}
	return errUsage
}
