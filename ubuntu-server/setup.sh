#!/bin/bash

# Set some default values:
NODE_VERSION="16.15.1"
PORT="3000"
USE_NPM=0

usage() {
    echo ""
    echo "Usage: setup [ -u | --github-url   ]
             [ -t | --type         ]
             [ -d | --domain       ]
             [ -p | --port         ]
             [ -n | --node-version ] 
             [ -b | --git-branch   ]
             [ -m | --use-npm      ]
             
* github-url:   [REQUIRED] This is the url of the remote repo in this format: https://[USERNAME]:[ACCESS_TOKEN]@github.com/[ORG]/[REPO]..

* type:         [REQUIRED] This indicates if the server is a frontend or backend one with value 'f' for frontend or 'b' for backend. If set to 'b', make sure to set 'domain'.

* domain:       This is the domain of the application. It is only required when the 'nginx' flag is set.

* port:         This indicates the port your application is running on. It defaults to 3000.

* node-version: This indicates the version of node you want installed on the server. It defaults to 16.15.1

* git-branch:   This indicates the branch of the remote repo to pull from. It defaults to the default branch.

* use-npm:      This is a flag that indicates if you want to 'npm' rather than the default 'yarn' package manager."

    exit 2
}

PARSED_ARGUMENTS=$(getopt -a -n setup -o "u:t:d:p:n:b:m" --long "github-url:,type:,domain:,port:,node-version:,git-branch:,use-npm" -- "$@")
VALID_ARGUMENTS=$?
if [ "$VALID_ARGUMENTS" != "0" ]; then
    usage
fi

eval set -- "$PARSED_ARGUMENTS"

while :; do
    case "$1" in
    -u | --github_url)
        GITHUB_URL="$2"
        shift 2
        ;;
    -t | --type)
        TYPE="$2"
        shift 2
        ;;
    -d | --domain)
        DOMAIN="$2"
        shift 2
        ;;
    -p | --port)
        PORT="$2"
        shift 2
        ;;
    -n | --node_version)
        NODE_VERSION="$2"
        shift 2
        ;;
    -b | --git-branch)
        GIT_BRANCH="$2"
        shift 2
        ;;
    -m | --use-npm)
        USE_NPM=1
        shift
        ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
    --)
        shift
        break
        ;;
        # If invalid options were passed, then getopt should have reported an error,
        # which we checked as VALID_ARGUMENTS when getopt was called...
    *)
        echo "Unexpected option: $1 - this should not happen."
        usage
        ;;
    esac
done

if [ -z "$GITHUB_URL" ]; then
    echo "'github_url' is required"
    usage
    exit 1
fi
if [ -z "$TYPE" ]; then
    echo "'type' is required"
    usage
    exit 1
fi
if [ "$TYPE" != "f" ] && [ "$TYPE" != "b" ]; then
    echo "'type' can only have value 'f' or 'b'"
    usage
    exit 1
fi

IS_BACKEND=$(expr "${TYPE}" == "b")

if [ "$IS_BACKEND" == "1" ]; then
    if [ -z "$DOMAIN" ]; then
        echo "'domain' is required for backends"
        usage
        exit 1
    fi
fi

set -e

sudo apt update -y
echo APT UPDATE DONE
echo ""

sudo apt install nodejs -y
echo \"NODE\" INSTALLED
echo ""

sudo apt install npm -y
echo \"NPM\" INSTALLED
echo ""

if [ "$USE_NPM" == 0 ]; then
    sudo npm install -g yarn
    echo \"YARN\" INSTALLED
    echo ""
fi

sudo npm install -g n
echo \"N\" INSTALLED
echo ""

sudo n "$NODE_VERSION"
echo NODE VERSION UPDATED TO "$NODE_VERSION"
echo ""

sudo npm install -g pm2
echo \"PM2\" INSTALLED
echo ""

if [ "$IS_BACKEND" == "1" ]; then
    sudo apt install nginx -y
    echo \"NGINX\" INSTALLED
    echo ""

    sudo -u root -H sh -c "echo \"server { listen 80; server_name $DOMAIN; location / { proxy_pass http://localhost:$PORT; } rewrite ^/(.*)/$ /$1 permanent; }\" > \"/etc/nginx/sites-available/$DOMAIN\""

    echo \"NGINX\" sites-available file created
    echo ""

    sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    sudo nginx -t
    sudo systemctl restart nginx
    echo \"NGINX\" RESTARTED
    echo ""

fi

if [ -d "app" ]; then
    cd app
    git pull
    echo PROJECT UPDATED FROM GITHUB
    echo ""
else
    git clone "$GITHUB_URL" app
    echo PROJECT CLONED FROM GITHUB
    echo ""
    cd app
fi

if [ -z "$GIT_BRANCH" ]; then
    echo "USING DEFAULT GIT BRANCH"
    echo ""
else
    git switch "$GIT_BRANCH"
fi

if [ "$USE_NPM" == "1" ]; then
    npm install
    echo PACKAGE INSTALLATION DONE WITH \"NPM\"
    echo ""

    NODE_ENV=production NUXT_TELEMETRY_DISABLED=1 npm run build
    echo PROJECT BUILT WITH \"NPM\"
    echo ""
else
    yarn install
    echo PACKAGE INSTALLATION DONE WITH \"YARN\"
    echo ""

    NODE_ENV=production NUXT_TELEMETRY_DISABLED=1 yarn run build
    echo PROJECT BUILT WITH \"YARN\"
    echo ""
fi

#start the app with pm2 from the built index file
if [ "$IS_BACKEND" == "1" ]; then
    NODE_ENV=production pm2 start dist/main.js --name "App"
    pm2 save
else
    sudo -i -u root bash <<EOF
PORT=80 NODE_ENV=production pm2 start /home/ubuntu/app/.output/server/index.mjs --name "App"
EOF
    sudo pm2 save
fi
echo APP STARTED
echo ""

cd ..
if [ "$IS_BACKEND" == "1" ]; then
    #BACKEND BLOCK
    if [ "$USE_NPM"=="1" ]; then
        cat <<EOF >update.sh
#!/bin/bash

cd app
pm2 stop all
git pull
npm install
NODE_ENV=production npm run build
NODE_ENV=production pm2 start all
EOF
    else
        cat <<EOF >update.sh
#!/bin/bash

cd app
pm2 stop all
git pull
yarn install --ignore-engines
NODE_ENV=production yarn run build
NODE_ENV=production pm2 start all
EOF
    fi
else
    #FRONTEND BLOCK
    if [ "$USE_NPM"=="1" ]; then
        cat <<EOF >update.sh
#!/bin/bash

sudo -u root -H sh -c "cd /home/ubuntu/app; pm2 stop all; git pull; npm install; NODE_ENV=production NUXT_TELEMETRY_DISABLED=1 npm run build; NODE_ENV=production pm2 start all;"
EOF
    else
        cat <<EOF >update.sh
#!/bin/bash

sudo -u root -H sh -c "cd /home/ubuntu/app; pm2 stop all; git pull; yarn install --ignore-engines; NODE_ENV=production NUXT_TELEMETRY_DISABLED=1 yarn run build; NODE_ENV=production pm2 start all;"
EOF
    fi
fi
chmod +x update.sh
echo UPDATE SCRIPT CREATED AND EXECUTABLE
echo ""

echo "NODE VERSION: $NODE_VERSION"
echo "GITHUB URL: $GITHUB_URL"
