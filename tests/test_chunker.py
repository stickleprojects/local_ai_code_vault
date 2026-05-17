from indexer.chunker import chunk_source, language_for


def test_language_detection_and_unsupported():
    assert language_for("a/b/foo.py") == "python"
    assert language_for("Foo.cs") == "csharp"
    assert language_for("x.JS") == "javascript"  # case-insensitive
    assert language_for("x.ts") == "typescript"
    assert language_for("comp.tsx") == "tsx"
    assert language_for("README.md") is None
    assert language_for("Makefile") is None


def test_python_functions_and_class_methods():
    src = b'''import os


def top_level():
    return 1


class Greeter:
    def hello(self):
        return "hi"
'''
    chunks = chunk_source("m.py", src, "python")
    kinds = {(c.start_line, c.end_line) for c in chunks}
    texts = "\n".join(c.text for c in chunks)
    # top-level function + the class + the method inside it.
    assert "def top_level" in texts
    assert "class Greeter" in texts
    assert "def hello" in texts
    # 1-based line numbers point at the right places.
    assert (4, 5) in kinds  # def top_level
    assert any(s == 8 for s, _ in kinds)  # class Greeter starts line 8


def test_csharp_class_and_method():
    src = b"""namespace Demo {
    public class Calc {
        public int Add(int a, int b) { return a + b; }
    }
}
"""
    chunks = chunk_source("Calc.cs", src, "csharp")
    text = "\n".join(c.text for c in chunks)
    assert "class Calc" in text
    assert "int Add" in text
    assert all(c.language == "csharp" for c in chunks)


def test_typescript_chunks():
    src = b"""export function add(a: number, b: number): number { return a + b; }
export class Box<T> { value!: T; get(): T { return this.value; } }
"""
    chunks = chunk_source("b.ts", src, "typescript")
    text = "\n".join(c.text for c in chunks)
    assert "function add" in text
    assert "class Box" in text


def test_script_with_no_declarations_falls_back_to_whole_file():
    src = b"x = 1\nprint(x)\n"
    chunks = chunk_source("s.py", src, "python")
    assert len(chunks) == 1
    assert chunks[0].start_line == 1
    assert "print(x)" in chunks[0].text


def test_empty_file_yields_no_chunks():
    assert chunk_source("e.py", b"   \n  \n", "python") == []
