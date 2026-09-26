"""
AuraBank – DB Init Lambda
Creates 4 schemas (auth_db, accounts_db, transactions_db, notifications_db)
and a dedicated PostgreSQL user for each schema, ensuring full isolation.
Run once after RDS provisioning.
"""
import json, os, boto3, psycopg2

sm = boto3.client("secretsmanager")

def get_secret(arn):
    resp = sm.get_secret_value(SecretId=arn)
    return json.loads(resp["SecretString"])

def handler(event, context):
    master = get_secret(os.environ["MASTER_SECRET_ARN"])
    host   = os.environ["DB_HOST"]
    port   = int(os.environ["DB_PORT"])
    dbname = os.environ["DB_NAME"]

    conn = psycopg2.connect(
        host=host, port=port, dbname=dbname,
        user=master["username"], password=master["password"],
        connect_timeout=10
    )
    conn.autocommit = True
    cur = conn.cursor()

    schemas = {
        "auth":          os.environ["AUTH_SECRET_ARN"],
        "accounts":      os.environ["ACCOUNTS_SECRET_ARN"],
        "transactions":  os.environ["TRANSACTIONS_SECRET_ARN"],
        "notifications": os.environ["NOTIFICATIONS_SECRET_ARN"],
    }

    for schema, secret_arn in schemas.items():
        creds  = get_secret(secret_arn)
        user   = creds["username"]
        passwd = creds["password"]
        db     = creds["dbname"]

        # Create schema
        cur.execute(f"CREATE SCHEMA IF NOT EXISTS {schema};")

        # Create user if not exists, otherwise sync password with Secrets Manager
        cur.execute(f"SELECT 1 FROM pg_roles WHERE rolname = %s", (user,))
        if not cur.fetchone():
            cur.execute(f"CREATE USER {user} WITH PASSWORD %s;", (passwd,))
        else:
            cur.execute(f"ALTER USER {user} WITH PASSWORD %s;", (passwd,))

        # Grant schema privileges
        cur.execute(f"GRANT USAGE ON SCHEMA {schema} TO {user};")
        cur.execute(f"GRANT CREATE ON SCHEMA {schema} TO {user};")
        cur.execute(f"ALTER DEFAULT PRIVILEGES IN SCHEMA {schema} GRANT ALL ON TABLES TO {user};")
        cur.execute(f"ALTER DEFAULT PRIVILEGES IN SCHEMA {schema} GRANT ALL ON SEQUENCES TO {user};")

        # Set default search path for user
        cur.execute(f"ALTER USER {user} SET search_path TO {schema}, public;")

        print(f"[OK] Schema '{schema}' and user '{user}' configured.")

    cur.close()
    conn.close()
    return {"statusCode": 200, "body": "DB init complete"}
