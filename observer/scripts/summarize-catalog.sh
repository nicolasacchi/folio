#!/bin/sh
set -eu

HOST="${KINDLE_HOST:-root@kindle}"
SSH_OPTS="${KINDLE_SSH_OPTS:--F /dev/null}"

ssh $SSH_OPTS "$HOST" "sqlite3 -separator '|' /var/local/cc.db \"
select
  p_isArchived,
  p_isVisibleInHome,
  p_contentState,
  p_originType,
  p_cdeType,
  p_type,
  p_mimeType,
  case
    when p_location is null then 'NULL'
    when p_location like 'file:%' then 'file'
    when p_location like '/%' then 'path'
    when p_location like 'http%' then 'http'
    else substr(p_location,1,20)
  end as location_kind,
  count(*)
from Entries
group by 1,2,3,4,5,6,7,8
order by 9 desc
limit 80;
\""

echo
ssh $SSH_OPTS "$HOST" "sqlite3 -separator '|' /var/local/cc.db \"
select
  p_isArchived,
  p_isVisibleInHome,
  count(*) as rows,
  sum(case when p_metadataUnicodeWords is not null and length(p_metadataUnicodeWords)>0 then 1 else 0 end) as searchable,
  sum(case when p_titles_0_nominal is not null and length(p_titles_0_nominal)>0 then 1 else 0 end) as titled,
  sum(case when p_credits_0_name_collation is not null and length(p_credits_0_name_collation)>0 then 1 else 0 end) as authored
from Entries
group by 1,2
order by rows desc;
\""
