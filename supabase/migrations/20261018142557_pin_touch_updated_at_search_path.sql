-- Pin search_path on the trigger function (Supabase security advisor 0011).
alter function public.touch_updated_at() set search_path = '';
