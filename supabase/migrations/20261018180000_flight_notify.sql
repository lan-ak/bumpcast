-- Per-flight "Tell me when it's ready or changes" (on by default). Off means the worker still
-- records updates for the in-app feed, but doesn't push them.
alter table public.flights add column notify boolean not null default true;
