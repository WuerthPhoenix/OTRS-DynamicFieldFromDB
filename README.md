OTRS-DynamicFieldFromDB
=======================


Description
-----------
OTRS-DynamicFieldFromDB adds a new dynamic field backend, which allows to use external databases as source for its values. All perl DBI DBMS are supported. 


Compatibility
-------------
OTRS 3.1.x
To use full functionalities the OTRS feature Add-on OTRSTicketMaskExtensions is required. To activate all features, apply all patches in the patches/ folder. 


Install
-------
Use the OTRS package manager to install the opm file located in the Github repository Downloads or build the opm using the sopm.
In order to be able to use the DynamicFieldFromDB add the needed parameters on each AJAXPossibleValuesGet call like this:
\# sed -i 's/\(AJAXPossibleValuesGet(\)$/\1%GetParam,ParamObject => \$Self->{ParamObject},/' /opt/otrs/Custom/Kernel/Modules/AgentTicketPhone.pm


Usage
-----
Once installed, find the new dynamic field type backend in the DynamicField Admin.


