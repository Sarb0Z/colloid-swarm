"""Generate a standalone, stdlib-only reference solution for a given dialect.

`reference_solution_code(params)` returns Python source defining
`evaluate(src) -> str` that implements exactly the dialect described by
`params`. It mirrors the oracle but reads its rules from an embedded dict, so it
is self-contained and runnable inside the sandbox (no import of the reference
package). Uses:
  * honest control in the soundness battery -- it must score 1.0, which proves
    the verifier does not reject correct solutions for harness reasons;
  * the top rung of the capability ladder;
  * the artifact a "competent human who read the spec" would converge to.
"""

from __future__ import annotations

import json

from .semantics import SemanticParams

_TEMPLATE = r'''
import json

PARAMS = json.loads(r"""__PARAMS_JSON__""")

COMPARE = {"<", "<=", ">", ">=", "==", "!="}
UNARY = {"-", "!"}
TIERS = PARAMS["tiers"]
CIDX = PARAMS["compare_tier_index"]
UIDX = PARAMS["unary_tier_index"]
BINARY_OPS = {op for i, t in enumerate(TIERS) if i != UIDX for op in t["ops"]}

class NIL:  # sentinel value (propagates)
    pass
class ParseError(Exception): pass
class EvalError(Exception): pass

_SYMS = sorted(["**","<=",">=","==","!=","&&","||","+","-","*","/","%","<",">","!","(",")"], key=len, reverse=True)

def tokenize(s):
    toks=[]; i=0; n=len(s)
    while i<n:
        c=s[i]
        if c.isspace(): i+=1; continue
        if c.isdigit():
            j=i
            while j<n and s[j].isdigit(): j+=1
            if j<n and (s[j].isalpha() or s[j]=="_"): raise ParseError()
            toks.append(("INT", int(s[i:j]))); i=j; continue
        if c.isalpha() or c=="_":
            j=i
            while j<n and (s[j].isalnum() or s[j]=="_"): j+=1
            w=s[i:j]
            if w=="true": toks.append(("BOOL", True))
            elif w=="false": toks.append(("BOOL", False))
            else: raise ParseError()
            i=j; continue
        for sym in _SYMS:
            if s.startswith(sym,i):
                toks.append(("OP",sym)); i+=len(sym); break
        else:
            raise ParseError()
    toks.append(("EOF",None))
    return toks

def op_tier(op):
    for i,t in enumerate(TIERS):
        if op in t["ops"]: return i
    raise KeyError(op)

class P:
    def __init__(self, toks): self.t=toks; self.p=0
    def peek(self): return self.t[self.p]
    def adv(self):
        x=self.t[self.p]; self.p+=1; return x
    def peek_bin(self):
        k,v=self.peek()
        if k=="OP" and v in BINARY_OPS: return v
        return None
    def parse(self):
        node=self.expr(0)
        if self.peek()[0]!="EOF": raise ParseError()
        return node
    def expr(self, mn):
        left=self.prefix()
        while True:
            op=self.peek_bin()
            if op is None: break
            tier=op_tier(op)
            if tier<mn: break
            if tier==CIDX:
                left=self.cmp(left, mn); continue
            assoc=TIERS[tier]["assoc"]
            self.adv()
            nm=tier+1 if assoc=="left" else tier
            right=self.expr(nm)
            left=("bin", op, left, right)
        return left
    def cmp(self, left, mn):
        omin=CIDX+1; ops=[]; operands=[left]
        while True:
            k,v=self.peek()
            if k=="OP" and v in COMPARE and CIDX>=mn:
                self.adv(); ops.append(v); operands.append(self.expr(omin))
            else: break
        if len(ops)==1: return ("bin", ops[0], operands[0], operands[1])
        return ("cmp", ops, operands)
    def prefix(self):
        k,v=self.peek()
        if k=="OP" and v in UNARY:
            self.adv(); return ("un", v, self.expr(UIDX))
        return self.atom()
    def atom(self):
        k,v=self.adv()
        if k=="INT": return ("int", v)
        if k=="BOOL": return ("bool", v)
        if k=="OP" and v=="(":
            e=self.expr(0)
            if self.adv()!=("OP",")"): raise ParseError()
            return e
        raise ParseError()

if PARAMS["int_model"] in ("wrap","saturate","error"):
    IMIN=-(1<<(PARAMS["int_bits"]-1)); IMAX=(1<<(PARAMS["int_bits"]-1))-1
else:
    IMIN=IMAX=None

def norm(x):
    m=PARAMS["int_model"]
    if m=="bigint": return x
    if IMIN<=x<=IMAX: return x
    if m=="error": raise EvalError()
    if m=="saturate": return IMIN if x<IMIN else IMAX
    span=1<<PARAMS["int_bits"]
    return (x-IMIN)%span+IMIN

def to_int(v):
    if isinstance(v,bool):
        if PARAMS["mix_bool_int"]=="coerce": return 1 if v else 0
        raise EvalError()
    if isinstance(v,int): return v
    raise EvalError()

def cond(v):
    if v is NIL: return NIL
    if isinstance(v,bool): return v
    if isinstance(v,int):
        return v!=0 if PARAMS["truthy"]=="nonzero" else v>0
    raise EvalError()

def truth(b):
    return bool(b) if PARAMS["compare_result"]=="bool" else (1 if b else 0)

def divzero():
    d=PARAMS["div_zero"]
    if d=="error": raise EvalError()
    return NIL if d=="nil" else 0

def divide(x,y):
    if y==0: return divzero()
    m=PARAMS["div_round"]
    if m=="trunc":
        q=abs(x)//abs(y); return -q if (x<0)!=(y<0) else q
    if m=="floor": return x//y
    q=x//y
    if x-q*y<0: q += 1 if y<0 else -1
    return q

def modulo(x,y):
    if y==0: return divzero()
    q=divide(x,y)
    if q is NIL: return NIL
    return x-q*y

def power(x,y):
    if y<0:
        p=PARAMS["pow_negative_exp"]
        if p=="error": raise EvalError()
        return NIL if p=="nil" else 0
    if x not in (-1,0,1) and y*x.bit_length() > 100000:
        raise EvalError()
    return x**y

def arith(op,a,b):
    if a is NIL or b is NIL: return NIL
    x=to_int(a); y=to_int(b)
    if op=="+": return norm(x+y)
    if op=="-": return norm(x-y)
    if op=="*": return norm(x*y)
    if op=="/":
        r=divide(x,y); return r if r is NIL else norm(r)
    if op=="%":
        r=modulo(x,y); return r if r is NIL else norm(r)
    if op=="**":
        r=power(x,y); return r if r is NIL else norm(r)
    raise EvalError()

def equal(a,b):
    if PARAMS["mix_bool_int"]=="coerce":
        na=(1 if a else 0) if isinstance(a,bool) else a
        nb=(1 if b else 0) if isinstance(b,bool) else b
        return na==nb
    if isinstance(a,bool)!=isinstance(b,bool): raise EvalError()
    return a==b

def compare(op,a,b):
    if a is NIL or b is NIL: return NIL
    if op in ("==","!="):
        r=equal(a,b); return truth(r if op=="==" else (not r))
    x=to_int(a); y=to_int(b)
    r={"<":x<y,"<=":x<=y,">":x>y,">=":x>=y}[op]
    return truth(r)

def ev(node):
    t=node[0]
    if t=="int": return norm(node[1])
    if t=="bool": return node[1]
    if t=="un":
        op=node[1]
        if op=="-":
            v=ev(node[2])
            return NIL if v is NIL else norm(-to_int(v))
        c=cond(ev(node[2]))
        return NIL if c is NIL else truth(not c)
    if t=="cmp":
        mode=PARAMS["compare_chain"]
        if mode=="error": raise EvalError()
        ops=node[1]; operands=node[2]
        if mode=="left":
            acc=ev(operands[0])
            for i,op in enumerate(ops):
                acc=compare(op,acc,ev(operands[i+1]))
            return acc
        prev=ev(operands[0])
        for i,op in enumerate(ops):
            cur=ev(operands[i+1])
            c=cond(compare(op,prev,cur))
            if c is NIL: return NIL
            if not c: return truth(False)
            prev=cur
        return truth(True)
    if t=="bin":
        op=node[1]
        if op in ("&&","||"):
            return ev_logic(node)
        if op in COMPARE:
            return compare(op, ev(node[2]), ev(node[3]))
        return arith(op, ev(node[2]), ev(node[3]))
    raise EvalError()

def ev_logic(node):
    op=node[1]; left=node[2]; right=node[3]
    if PARAMS["logic_shortcircuit"]:
        lv=ev(left); lc=cond(lv)
        if lc is NIL: return NIL
        short=(op=="&&" and not lc) or (op=="||" and lc)
        if short:
            if PARAMS["logic_return"]=="operand": return lv
            return truth(op=="||")
        rv=ev(right); rc=cond(rv)
        if rc is NIL: return NIL
        return rv if PARAMS["logic_return"]=="operand" else truth(bool(rc))
    lv=ev(left); rv=ev(right)
    lc=cond(lv)
    if lc is NIL: return NIL
    rc=cond(rv)
    if rc is NIL: return NIL
    decided_left=(op=="&&" and not lc) or (op=="||" and lc)
    if PARAMS["logic_return"]=="operand":
        return lv if decided_left else rv
    res=(lc and rc) if op=="&&" else (lc or rc)
    return truth(res)

def fmt(v):
    if v is NIL: return PARAMS["nil_token"]
    if isinstance(v,bool): return "true" if v else "false"
    if isinstance(v,int): return str(v)
    raise EvalError()

def evaluate(src):
    try:
        toks=tokenize(src)
        ast=P(toks).parse()
        return fmt(ev(ast))
    except (ParseError, EvalError, RecursionError):
        return PARAMS["error_token"]
'''


def reference_solution_code(params: SemanticParams) -> str:
    """Standalone source implementing `evaluate` for `params`."""
    params_json = json.dumps(params.to_dict())
    return _TEMPLATE.replace("__PARAMS_JSON__", params_json)
