set DIR $1
set FILE $2
set TITLE $3
set 

echo '<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="stylesheet" type="text/css" href="/style.css" />
<link rel="icon" type="image/png" href="assets/favicon.png" />
<title>'$TITLE' ~ Clarity Flowers</title>
</head>
<body>
'

if test -n $DIR
  if test $FILE = 'index';
    echo '<a href=\"..\">return home</a>';
  else;
    echo '<a href=\".\">'$DIR' index</a>';
  end;
end;

echo '
<main>
<header>
  <h1>'$TITLE'</h1>
'

