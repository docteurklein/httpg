
from xml.dom.minidom import parse, Node
import sys

d = parse(sys.argv[1])
def gen(e, indent):
    match e.nodeType:
        case Node.TEXT_NODE:
            t = e.data.replace("'", "''")
            yield f"{indent}xmltext('{t}'"
        case Node.ELEMENT_NODE:
            yield f"{indent}xmlelement(name {e.tagName}"
        case _:
            pass

    if e.attributes:
        yield ", xmlattributes("

        for i, (name, value) in enumerate(e.attributes.items()):
            if i > 0:
                yield ","
            yield f"\n{indent + "  "}'{value}' as \"{name}\"\n"
        yield f"{indent})"

    for child in e.childNodes:
        yield ", \n"
        yield from gen(child, indent + "  ")
    yield f")"

# print("select XMLSERIALIZE(document ")
print("".join(list(gen(d.documentElement, ""))))
# print("as text indent )")
