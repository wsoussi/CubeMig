import { OnInit } from '@angular/core';
import { Component } from '@angular/core';
import { LayoutService } from './service/app.layout.service';

@Component({
    selector: 'app-menu',
    templateUrl: './app.menu.component.html'
})
export class AppMenuComponent implements OnInit {

    model: any[] = [];

    constructor(public layoutService: LayoutService) { }

    ngOnInit() {
        this.model = [
            {
                label: 'Dashboard',
                items: [
                    { label: 'Overview', icon: 'pi pi-fw pi-home', routerLink: ['/'] },
                    { label: 'Migration', icon: 'pi pi-fw pi-file-export', routerLink: ['/migration'] },
                    { label: 'Simulation', icon: 'pi pi-fw pi-play', routerLink: ['/simulation'] },
                    { label: 'TEE Encapsulation', icon: 'pi pi-fw pi-shield', routerLink: ['/tee-encapsulation'] },
                    { label: 'Logs', icon: 'pi pi-fw pi-book', routerLink: ['/logs'] }
                ]
            }
        ];
    }
}
