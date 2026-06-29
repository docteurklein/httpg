\set title 'How I wrote this blog engine'
\set content `comrak --syntax-highlighting base16-ocean.dark --unsafe blog/how.md`

delete from blog.post where title = :'title';
insert into blog.post (title, content) values (:'title', :'content');
