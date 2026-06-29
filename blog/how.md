
Using SQL. Yes.

<!-- <iframe frameborder="0" scrolling="no" style="width:100%; height:331px;" allow="clipboard-write" src="https://emgithub.com/iframe.html?style=default&amp;type=code&amp;showBorder=on&amp;showLineNumbers=on&amp;showFileMeta=on&amp;showFullPath=on&amp;showCopy=on&amp;target=https%3A%2F%2Fgithub.com%2Fdocteurklein%2Fhttpg%2Fblob%2Fmain%2Fsql%2Fblog%2Findex.sql%23L11-L22"></iframe> -->

```rust
impl Visitor for Whitelist {
{
    type Break = ();

    fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
        self.0 = match expr {
            Expr::Function(Function { name, ..}) if name.to_string() == "set_config" => Err(HttpgError::RefusedSql {
                query: expr.to_string(),
                reason: Some("illegal set_config".to_string()),
            }),
            _ => Ok(()),
        };
        if self.0.is_err() {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_statement(&mut self, statement: &Statement) -> ControlFlow<Self::Break> {
        self.0 = if matches!(*statement,
              Statement::Query(_)
            | Statement::Call(_)
            | Statement::Insert(_)
            | Statement::Update(_)
            | Statement::Delete(_)
        ) {
            Ok(())
        } else {
            Err(HttpgError::RefusedSql { query: statement.to_string(), reason: Some("only DML".to_string()) })
        };
        if self.0.is_err() {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_query(&mut self, query: &Query) -> ControlFlow<Self::Break> {
        self.0 = if matches!(*query.body,
              SetExpr::Select(_)
            | SetExpr::Values(_)
            | SetExpr::Insert(_)
            | SetExpr::Update(_)
            | SetExpr::Delete(_)
            | SetExpr::Merge(_)
            | SetExpr::Table(_)
            | SetExpr::SetOperation {..}
        ) {
            Ok(())
        } else {
            Err(HttpgError::RefusedSql { query: query.to_string(), reason: Some("only DML".to_string()) })
        };
        if self.0.is_err() {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }
}
```

## check this

```sql

select * from blog.post where true
```
## check that


this is a rather long parapgraph, just to test stuff.
If you think I'm wrong pleas ecomment

this is a rather long parapgraph, just to test stuff.
If you think I'm wrong pleas ecomment

this is a rather long parapgraph, just to test stuff.
If you think I'm wrong pleas ecomment

yooo

