package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestTranscript(t *testing.T) {
	ok, failed, unanswered := okFg+"●"+reset+" ", errorFg+"●"+reset+" ", dim+"●"+reset+" "
	tests := []struct {
		name    string
		records []string
		want    string
	}{
		{
			"prompt and reply",
			[]string{
				`{"type":"user","message":{"content":"fix it"}}`,
				`{"type":"assistant","message":{"content":[{"type":"text","text":"On it: ` + "`make`" + `.\nDone."}]}}`,
			},
			"\n" + promptBlock("fix it", 0) + "\n" +
				"\n● On it: " + codeFg + "make" + reset + ".\n  Done.\n",
		},
		{
			"a slash command and an image sent with a prompt",
			[]string{
				`{"type":"user","message":{"content":"<command-message>c</command-message>\n<command-name>/compact</command-name>\n<command-args>keep tests</command-args>"}}`,
				`{"type":"user","message":{"content":[{"type":"text","text":"look"},{"type":"image","source":{}}]}}`,
			},
			"\n" + promptBlock("/compact keep tests", 0) + "\n" +
				"\n" + promptBlock("look", 0) + "\n\n" + promptBlock("[Image]", 0) + "\n",
		},
		{
			"thinking, kept or emptied",
			[]string{`{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm\nyes"},{"type":"thinking","thinking":""}]}}`},
			"\n" + dim + italic + "✻ Thinking…" + reset + "\n  " + dim + italic + "hmm" + reset + "\n  " + dim + italic + "yes" + reset + "\n",
		},
		{
			"a call, its other input and its result",
			[]string{
				`{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls\n-la","description":"List"}}]}}`,
				`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a\nb\n"}]}}`,
			},
			"\n" + ok + bold + "Bash" + reset + "\n  " + dim + "command:" + reset + " ls\n    -la\n  " + dim + "description:" + reset + " List\n  ⎿  a\n     b\n",
		},
		{
			"an edit as its input in the order stored, whatever its result recorded",
			[]string{
				`{"type":"assistant","message":{"content":[{"type":"tool_use","id":"e1","name":"Edit","input":{"replace_all":false,"file_path":"/f","old_string":"a","new_string":"b\nc"}}]}}`,
				`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"e1","content":"updated"}]},"toolUseResult":{"structuredPatch":[{"oldStart":9,"newStart":9,"lines":["-a","+b"]}]}}`,
			},
			"\n" + ok + bold + "Edit" + reset + "\n" +
				"  " + dim + "replace_all:" + reset + " false\n" +
				"  " + dim + "file_path:" + reset + " /f\n" +
				"  " + dim + "old_string:" + reset + " a\n" +
				"  " + dim + "new_string:" + reset + " b\n    c\n  ⎿  updated\n",
		},
		{
			"a failed call, and one never answered",
			[]string{
				`{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x"}},{"type":"tool_use","id":"t2","name":"X","input":{"limit":3,"path":"/"}}]}}`,
				`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"no such file"}]}}`,
			},
			"\n" + failed + bold + "Read" + reset + "\n  " + dim + "file_path:" + reset + " /x\n  ⎿  " + errorFg + "no such file" + reset + "\n" +
				"\n" + unanswered + bold + "X" + reset + "\n  " + dim + "limit:" + reset + " 3\n  " + dim + "path:" + reset + " /\n",
		},
		{
			"an input key's control characters",
			[]string{`{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"X","input":{"a\u001b]52;c;eA==\u0007b":"v"}}]}}`},
			"\n" + unanswered + bold + "X" + reset + "\n  " + dim + "a ]52;c;eA== b:" + reset + " v\n",
		},
		{
			"a result in blocks, and an empty one",
			[]string{
				`{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"ToolSearch","input":{"query":"q"}},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"true"}}]}}`,
				`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"found"},{"type":"tool_reference","tool_name":"Monitor"},{"type":"image","source":{}}]},{"type":"tool_result","tool_use_id":"t2","content":""}]}}`,
			},
			"\n" + ok + bold + "ToolSearch" + reset + "\n  " + dim + "query:" + reset + " q\n  ⎿  found\n     Monitor\n     [Image]\n" +
				"\n" + ok + bold + "Bash" + reset + "\n  " + dim + "command:" + reset + " true\n  ⎿  " + dim + "(No content)" + reset + "\n",
		},
		{
			"what the preview leaves out",
			[]string{
				`{"type":"user","isMeta":true,"message":{"content":"meta text"}}`,
				`{"type":"user","isSidechain":true,"message":{"content":"side prompt"}}`,
				`{"type":"user","isCompactSummary":true,"message":{"content":"Summary text"}}`,
				`{"type":"user","message":{"content":"<system-reminder>remember</system-reminder>"}}`,
				`{"type":"user","message":{"content":"<local-command-stdout>out</local-command-stdout>"}}`,
				`{"type":"user","message":{"content":"<bash-input>ls</bash-input>"}}`,
				`{"type":"user","message":{"content":"<task-notification><summary>done</summary></task-notification>"}}`,
				`{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}`,
				`{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}`,
				`{"type":"attachment","attachment":{"type":"queued_command","prompt":"also this"}}`,
				`{"type":"ai-title","aiTitle":"Fixing"}`,
			},
			"",
		},
	}
	for _, tt := range tests {
		var out bytes.Buffer
		transcript(&out, []byte(strings.Join(tt.records, "\n")+"\n"), 0)
		if got := out.String(); got != tt.want {
			t.Errorf("%s:\n got %q\nwant %q", tt.name, got, tt.want)
		}
	}
}

func TestKeepSGR(t *testing.T) {
	tests := []struct{ in, want string }{
		{"plain\ttab\nline", "plain\ttab\nline"},
		{"\x1b[31mred\x1b[0m \x1b[38;2;1;2;3mx", "\x1b[31mred\x1b[0m \x1b[38;2;1;2;3mx"},
		{"\x1b]52;c;eA==\x07a \x1b]0;title\x1b\\b", "a b"},
		{"\x1b[2J\x1b[Hcleared", "cleared"},
		{"a\rb\x07c\u009bd", "abcd"},
		{"cut\x1b", "cut"},
	}
	for _, tt := range tests {
		if got := keepSGR(tt.in); got != tt.want {
			t.Errorf("keepSGR(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestFieldsOf(t *testing.T) {
	fields := fieldsOf([]byte(`{"b":1,"a":"x","c":[1,2]}`))
	var keys []string
	for _, f := range fields {
		keys = append(keys, f.key+"="+string(f.value))
	}
	if got := strings.Join(keys, " "); got != `b=1 a="x" c=[1,2]` {
		t.Errorf("fieldsOf = %s", got)
	}
	if fieldsOf([]byte(`"not an object"`)) != nil || fieldsOf(nil) != nil {
		t.Error("fieldsOf read fields out of no object")
	}
}
