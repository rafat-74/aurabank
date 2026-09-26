-- AuraBank – Local Dev Schema Init
-- Mirrors what the Lambda does on RDS in AWS
-- Runs automatically on first postgres container start

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS accounts;
CREATE SCHEMA IF NOT EXISTS transactions;
CREATE SCHEMA IF NOT EXISTS notifications;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'auth_user') THEN
    CREATE USER auth_user WITH PASSWORD 'auth_local_pass';
  END IF;
END $$;
GRANT USAGE, CREATE ON SCHEMA auth TO auth_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON TABLES TO auth_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON SEQUENCES TO auth_user;
ALTER USER auth_user SET search_path TO auth, public;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'accounts_user') THEN
    CREATE USER accounts_user WITH PASSWORD 'accounts_local_pass';
  END IF;
END $$;
GRANT USAGE, CREATE ON SCHEMA accounts TO accounts_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA accounts GRANT ALL ON TABLES TO accounts_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA accounts GRANT ALL ON SEQUENCES TO accounts_user;
ALTER USER accounts_user SET search_path TO accounts, public;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'transactions_user') THEN
    CREATE USER transactions_user WITH PASSWORD 'transactions_local_pass';
  END IF;
END $$;
GRANT USAGE, CREATE ON SCHEMA transactions TO transactions_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA transactions GRANT ALL ON TABLES TO transactions_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA transactions GRANT ALL ON SEQUENCES TO transactions_user;
ALTER USER transactions_user SET search_path TO transactions, public;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'notifications_user') THEN
    CREATE USER notifications_user WITH PASSWORD 'notifications_local_pass';
  END IF;
END $$;
GRANT USAGE, CREATE ON SCHEMA notifications TO notifications_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA notifications GRANT ALL ON TABLES TO notifications_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA notifications GRANT ALL ON SEQUENCES TO notifications_user;
ALTER USER notifications_user SET search_path TO notifications, public;
