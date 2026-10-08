insert into blog.post (title, content) select random()::text, random()::text from generate_series(1, random(3, 5));
delete from blog.post where post_id in (select post_id from blog.post limit random(3, 5));
-- update blog.post set content = random() where content::float < 0.6;
insert into blog.comment (author, content, post_id) select random()::text, random()::text, post_id from blog.post, generate_series(2, random(4, 6)) limit 2;
delete from blog.comment where comment_id in (select comment_id from blog.comment limit random(3, 5));
