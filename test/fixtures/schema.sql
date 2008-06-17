
CREATE TABLE 'accounts' (
  'id' INTEGER PRIMARY KEY NOT NULL,
  'name' TEXT DEFAULT NULL
);

CREATE TABLE 'users' (
  'id' INTEGER PRIMARY KEY NOT NULL, 
  'name' text, 
  'account_id' integer
);

CREATE TABLE 'interests' (
  'id' INTEGER PRIMARY KEY NOT NULL, 
  'user_id' INTEGER DEFAULT NULL,
  'title' varchar(255), 
  'content' text
);

CREATE TABLE 'projects' (
  'id' INTEGER PRIMARY KEY NOT NULL,
  'name' TEXT DEFAULT NULL
);

CREATE TABLE 'projects_users' (
  'user_id' INTEGER NOT NULL,
  'project_id' INTEGER NOT NULL
);
