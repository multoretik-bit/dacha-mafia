-- 30.10: fouls per seat (3 = player leaves), priest becomes a base role
alter table public.seats add column if not exists fouls int not null default 0;

update public.seats
set role_id = 'pri', role_code = 'PRS', role_art = 'cards/pri.webp',
    role_desc = 'Ты на стороне города. Ночью делаешь свой ход по правилам ведущего, днём помогай найти мафию.'
where role_id = 'c_sxoxf0xjz8x5';
