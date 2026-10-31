-- Private bucket for the worker's archive of NOAA's GTG forecast (worker/src/smooth_worker/archive.py),
-- the training data for our own turbulence outlook. Only the service role reads or writes it: no
-- policies on storage.objects for this bucket, so the app's anonymous users never see it.
-- ~20 files a day of ~390 KB; the size limit is far above any one hour's file.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('archive', 'archive', false, 10485760, array['application/octet-stream'])
on conflict (id) do nothing;
