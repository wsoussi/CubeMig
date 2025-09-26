import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';
import {OverviewComponent} from './pages/overview/overview.component';
import {MigrationComponent} from './pages/migration/migration.component';
import {LogsComponent} from './pages/logs/logs.component';
import {ConfigComponent} from './pages/config/config.component';
import { AppLayoutComponent } from './layout/app.layout.component';
import { SimulationComponent } from './pages/simulation/simulation.component';
import { TeeEncapsulationComponent } from './pages/tee-encapsulation/tee-encapsulation.component';

const routes: Routes = [
  {
    path: '', component: AppLayoutComponent,
    children: [
      { path: '', component: OverviewComponent },
      { path: 'migration', component: MigrationComponent },
      { path: 'simulation', component: SimulationComponent },
      { path: 'tee-encapsulation', component: TeeEncapsulationComponent },
      { path: 'logs', component: LogsComponent },
      { path: 'config', component: ConfigComponent}
    ]
  },
  {
    path: 'config', component: ConfigComponent,
  }
];

@NgModule({
  imports: [RouterModule.forRoot(routes)],
  exports: [RouterModule]
})
export class AppRoutingModule { }
