set session characteristics as transaction isolation level serializable;
set "auto_explain.log_min_duration" = 10000;
-- truncate blog.post cascade;
insert into blog.post (title, content) select random()::text, random()::text from generate_series(1, random(5, 10));
delete from blog.post where post_id in (select post_id from blog.post order by random() limit random(5, 10)) and random(1, 10) > 2;
-- update blog.post set content = random() where content::float < 0.6;
insert into blog.comment (author, content, post_id) select random()::text, random()::text, post_id from (select * from blog.post order by random() limit 10), generate_series(3, random(4, 10));
delete from blog.comment where comment_id in (select comment_id from blog.comment order by random() limit random(3, 10));
