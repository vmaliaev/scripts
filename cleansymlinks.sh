#!/bin/bash
exIP="10.89.12.43 10.89.12.44 10.89.12.46 10.89.12.47 10.89.12.48 10.89.12.50 10.89.12.51 10.89.12.53 10.89.12.54 10.89.12.55 10.89.12.56"
exNA="node-{67}.infra.covisint.comnode-{68}.infra.covisint.comnode-{69}.infra.covisint.comnode-{70}.infra.covisint.comnode-{71}.infra.covisint.comnode-{72}.infra.covisint.comnode-{73}.infra.covisint.comnode-{74}.infra.covisint.comnode-{75}.infra.covisint.comnode-{76}.infra.covisint.comnode-{77}.infra.covisint.comnode-{78}.infra.covisint.comnode-{79}.infra.covisint.comnode-{80}.infra.covisint.com"
f="cleanfolders.sh"

echo '#!/bin/bash' > $f

for i in `ls .`
do
 c=`expr "$exIP" : ".*\($i\)" ` #get substring $i from $exIP
 if [ -z $c ] && [ -L $i ] ;  then echo "rm $i" >> $f    ;  fi   # if did not found then delete symlink
done

chmod +x $f

