# Shared types for the constraint matrix and the solver (docs/interfaces.md).
#   Sym  = G.Vec        packed symbol, 4 octets per U32 word (see docs/gf256.md)
#   Term = Term{col, coef}   coef is a GF(256) octet (1 for binary entries)
#   Row  = Row{cols, rhs}    sum(coef_i * C[col_i]) = rhs
#   Rcv  = Rcv{esi, sym}     a received encoding symbol (external ESI)
# All are `Data` (reusable without `+`); lists of them are `List<&2, _>`.
import Base
import ./gf256.bend as G

type Term is Data:
  Term{col: U32, coef: U32}

type Row is Data:
  Row{cols: List<&2, Term>, rhs: G.Vec}

type Rcv is Data:
  Rcv{esi: U32, sym: G.Vec}

def Term.col(t: Term) -> U32:
  match t:
    case Term{col, coef}:
      col

def Term.coef(t: Term) -> U32:
  match t:
    case Term{col, coef}:
      coef

def Row.cols(r: Row) -> List<&2, Term>:
  match r:
    case Row{cols, rhs}:
      cols

def Row.rhs(r: Row) -> G.Vec:
  match r:
    case Row{cols, rhs}:
      rhs
